# frozen_string_literal: true
# Operator preflight: reads public identity configuration via authenticated GitHub REST GETs.
# No ID token is requested and no AWS API is called. Run from a reviewed checkout.
require 'json'
require 'open3'
require 'yaml'

module ReleaseOidc
  ROLES = { 'frontend' => 'FrontendReleaseRole', 'backend' => 'ApiReleaseRole' }.freeze

  def self.verify!(repo, config, resources)
    role = ROLES.fetch(repo)
    raise "#{repo}: invalid OIDC configuration response" unless config.is_a?(Hash)
    prefix = config['sub_claim_prefix']
    unless config['use_default'] == true && config['use_immutable_subject'] == true &&
           prefix.is_a?(String) && /\Arepo:private-mailhub@[0-9]+\/#{Regexp.escape(repo)}@[0-9]+\z/.match?(prefix)
      raise "#{repo}: expected the default immutable repository subject; review issuer settings before deployment"
    end

    # Reject additional statements, federated principals, OR alternatives and StringLike as well as drift.
    statement = { 'Effect' => 'Allow', 'Action' => 'sts:AssumeRoleWithWebIdentity',
                  'Principal' => { 'Federated' => { 'Ref' => 'GitHubOidcProviderArn' } },
                  'Condition' => { 'StringEquals' => {
                    'token.actions.githubusercontent.com:aud' => 'sts.amazonaws.com',
                    'token.actions.githubusercontent.com:sub' => "#{prefix}:environment:production"
                  } } }
    return if resources.fetch(role).dig('Properties', 'AssumeRolePolicyDocument', 'Statement') == [statement]

    raise "#{repo}: template trust does not match GitHub's exact production identity; do not provision or deploy"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    resources = YAML.safe_load(File.read(File.join(__dir__, 'foundation.yaml'))).fetch('Resources')
    ReleaseOidc::ROLES.each_key do |repo|
      json, _, status = Open3.capture3('gh', 'api', '--hostname', 'github.com', '--method', 'GET',
                                       "repos/private-mailhub/#{repo}/actions/oidc/customization/sub")
      abort "#{repo}: cannot read GitHub OIDC configuration; check gh login and repository access" unless status.success?
      ReleaseOidc.verify!(repo, JSON.parse(json), resources)
      puts "#{repo}: exact immutable production subject matches the local template"
    end
  rescue Errno::ENOENT, KeyError, TypeError, JSON::ParserError, RuntimeError => e
    # Never print a GitHub response, bearer or JWT. A data-shape error is not a pass.
    abort(e.instance_of?(RuntimeError) ? e.message : 'Could not verify OIDC metadata; check gh, the template and the API response format')
  end
end
