# frozen_string_literal: true
# Standalone, offline CloudFormation contract. All intrinsics use long-form YAML.
require 'yaml'
require 'minitest/autorun'

class HostIdentityTest < Minitest::Test
  TEMPLATE = YAML.safe_load(File.read(File.join(__dir__, 'host-identity.yaml')))
  RESOURCES = TEMPLATE.fetch('Resources')

  def test_no_inputs_transforms_or_extra_resources
    assert_equal %w[AWSTemplateFormatVersion Description Outputs Resources Rules], TEMPLATE.keys.sort
    assert_equal({ 'HostRole' => 'AWS::IAM::Role', 'HostProfile' => 'AWS::IAM::InstanceProfile' },
                 RESOURCES.transform_values { |resource| resource.fetch('Type') })
  end

  def test_region_guard_is_unconditional
    rules = TEMPLATE.fetch('Rules')
    assert_equal ['ProductionRegion'], rules.keys
    rule = rules.fetch('ProductionRegion')
    assert_equal ['Assertions'], rule.keys
    assertions = rule.fetch('Assertions')
    assert_equal 1, assertions.size
    assert_equal({ 'Fn::Equals' => [{ 'Ref' => 'AWS::Region' }, 'us-east-1'] }, assertions.first.fetch('Assert'))
  end

  def test_role_has_only_ec2_trust_and_no_permissions_or_explicit_name
    role = RESOURCES.fetch('HostRole').fetch('Properties')
    assert_equal ['AssumeRolePolicyDocument'], role.keys
    assert_equal({ 'Version' => '2012-10-17', 'Statement' => [
                   { 'Effect' => 'Allow', 'Action' => 'sts:AssumeRole', 'Principal' => { 'Service' => 'ec2.amazonaws.com' } }
                 ] }, role.fetch('AssumeRolePolicyDocument'))
  end

  def test_unnamed_profile_contains_only_this_role
    assert_equal({ 'Roles' => [{ 'Ref' => 'HostRole' }] }, RESOURCES.fetch('HostProfile').fetch('Properties'))
  end

  def test_both_identities_survive_deletion_and_replacement
    RESOURCES.each do |id, resource|
      assert_equal %w[DeletionPolicy Properties Type UpdateReplacePolicy], resource.keys.sort, id
      assert_equal 'Retain', resource.fetch('DeletionPolicy'), id
      assert_equal 'Retain', resource.fetch('UpdateReplacePolicy'), id
    end
  end

  def test_outputs_are_only_friendly_names
    assert_equal({ 'InstanceRoleName' => { 'Value' => { 'Ref' => 'HostRole' } },
                   'InstanceProfileName' => { 'Value' => { 'Ref' => 'HostProfile' } } }, TEMPLATE.fetch('Outputs'))
  end
end
