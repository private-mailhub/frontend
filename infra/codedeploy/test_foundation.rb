# frozen_string_literal: true
# Local template contract tests. No AWS SDK, credentials, network, or filesystem writes.
require 'yaml'
require 'minitest/autorun'
require_relative 'verify_oidc'

class FoundationTest < Minitest::Test
  TEMPLATE = YAML.safe_load(File.read(File.join(__dir__, 'foundation.yaml')))
  RES = TEMPLATE.fetch('Resources')
  SERVICES = { 'Frontend' => %w[frontend frontend], 'Api' => %w[backend api] }.freeze
  # Public repository identity metadata, independent of the template under test.
  ISSUER_PREFIX = {
    'frontend' => 'repo:private-mailhub@301659027/frontend@1359848410',
    'backend' => 'repo:private-mailhub@301659027/backend@1126574189'
  }.freeze
  REGION = 'us-east-1'
  CONFIG = 'CodeDeployDefault.OneAtATime'
  CD = 'arn:${AWS::Partition}:codedeploy:${AWS::Region}:${AWS::AccountId}:'
  def ref(id); { 'Ref' => id }; end
  def sub(text); { 'Fn::Sub' => text }; end
  def arn(id); { 'Fn::GetAtt' => [id, 'Arn'] }; end
  def props(id); RES.fetch(id).fetch('Properties'); end
  def statements(policy); policy.fetch('PolicyDocument').fetch('Statement'); end
  def matches_param(id, value)
    pattern = TEMPLATE.fetch('Parameters').fetch(id).fetch('AllowedPattern')
    /\A(?:#{pattern})\z/.match?(value)
  end

  def test_no_network_compute_custom_resource_profile_or_implicit_deployment
    expected = %w[AWS::S3::Bucket AWS::S3::BucketPolicy AWS::IAM::ManagedPolicy] +
      ['AWS::IAM::Role'] * 3 + ['AWS::CodeDeploy::Application'] * 2 + ['AWS::CodeDeploy::DeploymentGroup'] * 2
    assert_equal expected.sort, RES.values.map { |r| r.fetch('Type') }.sort
    refute TEMPLATE.key?('Transform')
    assert_equal({ 'Fn::Equals' => [ref('AWS::Region'), REGION] },
                 TEMPLATE.fetch('Rules').fetch('ProductionRegion').fetch('Assertions').fetch(0).fetch('Assert'))
    SERVICES.each_key do |s|
      assert_equal 'Server', props("#{s}Application").fetch('ComputePlatform')
      group = props("#{s}DeploymentGroup")
      assert_equal %w[ApplicationName AutoRollbackConfiguration DeploymentConfigName DeploymentStyle Ec2TagFilters OutdatedInstancesStrategy ServiceRoleArn], group.keys.sort
      assert_equal ref("#{s}Application"), group.fetch('ApplicationName')
      assert_equal arn('DiscoveryRole'), group.fetch('ServiceRoleArn')
      assert_equal [{ 'Type' => 'KEY_AND_VALUE', 'Key' => ref('HostTagKey'), 'Value' => ref('HostTagValue') }], group.fetch('Ec2TagFilters')
      assert_equal({ 'DeploymentType' => 'IN_PLACE', 'DeploymentOption' => 'WITHOUT_TRAFFIC_CONTROL' }, group.fetch('DeploymentStyle'))
      assert_equal CONFIG, group.fetch('DeploymentConfigName')
      assert_equal 'IGNORE', group.fetch('OutdatedInstancesStrategy')
      assert_equal({ 'Enabled' => true, 'Events' => ['DEPLOYMENT_FAILURE'] }, group.fetch('AutoRollbackConfiguration'))
    end
    %w[HostTagKey HostTagValue].each do |p|
      refute TEMPLATE.fetch('Parameters').fetch(p).key?('Default')
      ['', '*', 'Prod*'].each { |bad| refute matches_param(p, bad) }
      assert matches_param(p, 'AnExplicitTag')
    end
  end

  def test_bucket_is_private_versioned_retained_with_no_completed_release_expiration
    bucket = props('Artifacts')
    assert_equal({ 'Status' => 'Enabled' }, bucket.fetch('VersioningConfiguration'))
    assert_equal 'AES256', bucket.dig('BucketEncryption', 'ServerSideEncryptionConfiguration', 0, 'ServerSideEncryptionByDefault', 'SSEAlgorithm')
    assert_equal [{ 'ObjectOwnership' => 'BucketOwnerEnforced' }], bucket.dig('OwnershipControls', 'Rules')
    assert_equal %w[BlockPublicAcls BlockPublicPolicy IgnorePublicAcls RestrictPublicBuckets].map { |key| [key, true] }.to_h,
                 bucket.fetch('PublicAccessBlockConfiguration')
    rules = bucket.dig('LifecycleConfiguration', 'Rules')
    assert_equal 1, rules.size
    assert_equal %w[AbortIncompleteMultipartUpload Id Status], rules.first.keys.sort
    assert_equal 'Enabled', rules.first.fetch('Status')
    assert_operator rules.first.dig('AbortIncompleteMultipartUpload', 'DaysAfterInitiation'), :>, 0
    %w[Artifacts ArtifactTransportPolicy].each do |id|
      %w[DeletionPolicy UpdateReplacePolicy].each { |policy| assert_equal 'Retain', RES.fetch(id).fetch(policy) }
    end
    assert_equal ref('Artifacts'), props('ArtifactTransportPolicy').fetch('Bucket')
    tls = statements(props('ArtifactTransportPolicy'))
    assert_equal 1, tls.size
    assert_equal ['Deny', '*', 's3:*'], tls.first.values_at('Effect', 'Principal', 'Action')
    assert_equal [arn('Artifacts'), sub('${Artifacts.Arn}/*')], tls.first.fetch('Resource')
    assert_equal({ 'Bool' => { 'aws:SecureTransport' => 'false' } }, tls.first.fetch('Condition'))
  end

  def test_oidc_trust_cannot_cross_repository_or_environment
    provider = "arn:aws:iam::#{'0' * 12}:oidc-provider/token.actions.githubusercontent.com"
    assert matches_param('GitHubOidcProviderArn', provider)
    refute matches_param('GitHubOidcProviderArn', provider + '/other')
    refute matches_param('GitHubOidcProviderArn', provider.sub('token.actions.', 'untrusted.'))
    SERVICES.each do |s, (repo, _prefix)|
      role = props("#{s}ReleaseRole")
      assert_equal %w[AssumeRolePolicyDocument Policies], role.keys.sort
      claims = { 'token.actions.githubusercontent.com:aud' => 'sts.amazonaws.com',
                 'token.actions.githubusercontent.com:sub' => "#{ISSUER_PREFIX.fetch(repo)}:environment:production" }
      assert_equal [{ 'Effect' => 'Allow', 'Principal' => { 'Federated' => ref('GitHubOidcProviderArn') },
                      'Action' => 'sts:AssumeRoleWithWebIdentity', 'Condition' => { 'StringEquals' => claims } }],
                   role.fetch('AssumeRolePolicyDocument').fetch('Statement')
    end
  end

  def test_operator_preflight_compares_live_metadata_without_trusting_names_or_wildcards
    ISSUER_PREFIX.each do |repo, prefix|
      cfg = { 'use_default' => true, 'use_immutable_subject' => true, 'sub_claim_prefix' => prefix }
      assert_nil ReleaseOidc.verify!(repo, cfg, RES)
      [{ 'use_default' => false }, { 'use_immutable_subject' => false },
       { 'sub_claim_prefix' => prefix.sub('@301659027/', '@123/') },
       { 'sub_claim_prefix' => prefix.sub(/@[0-9]+\z/, '@999') },
       { 'sub_claim_prefix' => "repo:private-mailhub/#{repo}" },
       { 'sub_claim_prefix' => ISSUER_PREFIX.values.find { |other| other != prefix } },
       { 'sub_claim_prefix' => nil }].each do |change|
        assert_raises(RuntimeError) { ReleaseOidc.verify!(repo, cfg.merge(change), RES) }
      end
    end
    role = 'FrontendReleaseRole'
    cfg = { 'use_default' => true, 'use_immutable_subject' => true, 'sub_claim_prefix' => ISSUER_PREFIX.fetch('frontend') }
    { 'token.actions.githubusercontent.com:aud' => '*',
      'token.actions.githubusercontent.com:sub' => "#{cfg['sub_claim_prefix']}:environment:staging" }.each do |key, bad|
      modified = JSON.parse(JSON.generate(RES))
      statement = modified.dig(role, 'Properties', 'AssumeRolePolicyDocument', 'Statement').first
      statement.fetch('Condition').fetch('StringEquals')[key] = bad
      assert_raises(RuntimeError) { ReleaseOidc.verify!('frontend', cfg, modified) }
    end
  end

  def test_exhaustive_publisher_action_resource_pairs
    SERVICES.each do |s, (_repo, prefix)|
      application = '${' + s + 'Application}'
      group = '${' + s + 'DeploymentGroup}'
      expected = {
        's3:GetBucketVersioning' => arn('Artifacts'), 's3:PutObject' => sub("${Artifacts.Arn}/#{prefix}/*"),
        'codedeploy:CreateDeployment' => sub("#{CD}deploymentgroup:#{application}/#{group}"),
        'codedeploy:GetDeployment' => sub("#{CD}deploymentgroup:#{application}/#{group}"),
        'codedeploy:GetApplicationRevision' => sub("#{CD}application:#{application}"),
        'codedeploy:RegisterApplicationRevision' => sub("#{CD}application:#{application}"),
        'codedeploy:GetDeploymentConfig' => sub("#{CD}deploymentconfig:#{CONFIG}")
      }
      actual = {}
      props("#{s}ReleaseRole").fetch('Policies').each do |policy|
        statements(policy).each do |st|
          assert_equal %w[Action Effect Resource], st.keys.sort - ['Sid']
          assert_equal 'Allow', st.fetch('Effect')
          Array(st.fetch('Action')).each do |action|
            refute actual.key?(action), "duplicate grant: #{s} #{action}"
            actual[action] = st.fetch('Resource')
          end
        end
      end
      assert_equal expected, actual, "#{s}: no broad/extra grants or cross-repo writes, group or revision access"
    end
  end

  def test_discovery_role_and_additive_optional_host_policy
    discovery = props('DiscoveryRole')
    assert_equal %w[AssumeRolePolicyDocument Policies], discovery.keys.sort
    assert_equal [{ 'Effect' => 'Allow', 'Principal' => { 'Service' => "codedeploy.#{REGION}.amazonaws.com" }, 'Action' => 'sts:AssumeRole' }],
                 discovery.fetch('AssumeRolePolicyDocument').fetch('Statement')
    assert_equal [{ 'Effect' => 'Allow', 'Resource' => '*', 'Action' => %w[ec2:DescribeInstances ec2:DescribeInstanceStatus tag:GetResources],
                    'Condition' => { 'StringEquals' => { 'aws:RequestedRegion' => REGION } } }],
                 discovery.fetch('Policies').flat_map { |p| statements(p) }
    assert_equal '', TEMPLATE.dig('Parameters', 'ExistingInstanceRoleName', 'Default')
    assert matches_param('ExistingInstanceRoleName', '')
    assert matches_param('ExistingInstanceRoleName', 'AnExistingRole')
    refute matches_param('ExistingInstanceRoleName', 'path/to/a/profile')
    assert_equal({ 'Fn::Not' => [{ 'Fn::Equals' => [ref('ExistingInstanceRoleName'), ''] }] }, TEMPLATE.dig('Conditions', 'AttachInstanceReadPolicy'))
    host = props('InstanceArtifactReadPolicy')
    assert_equal %w[Description PolicyDocument Roles], host.keys.sort
    assert_equal({ 'Fn::If' => ['AttachInstanceReadPolicy', [ref('ExistingInstanceRoleName')], ref('AWS::NoValue')] }, host.fetch('Roles'))
    assert_equal [{ 'Effect' => 'Allow', 'Action' => %w[s3:GetObject s3:GetObjectVersion],
                    'Resource' => [sub('${Artifacts.Arn}/frontend/*'), sub('${Artifacts.Arn}/api/*')] }], statements(host)
  end

  def test_outputs_match_each_runners_contract
    contract = { 'Region' => ref('AWS::Region'), 'DeployBucket' => ref('Artifacts'),
                 'InstanceReadPolicyArn' => ref('InstanceArtifactReadPolicy') }
    SERVICES.each_key do |s|
      contract["#{s}RoleArn"] = arn("#{s}ReleaseRole")
      contract["#{s}App"] = ref("#{s}Application")
      contract["#{s}Group"] = ref("#{s}DeploymentGroup")
    end
    assert_equal contract, TEMPLATE.fetch('Outputs').transform_values { |out| out.fetch('Value') }
  end
end
