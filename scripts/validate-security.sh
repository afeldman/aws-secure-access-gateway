#!/bin/bash
# Security Validation Script for AWS Secure Access Gateway + Honeytrap
# This script validates that security properties are enforced correctly

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
REGION="${AWS_REGION:-eu-central-1}"
GATEWAY_INSTANCE_ID="${GATEWAY_INSTANCE_ID:-}"
HONEYTRAP_INSTANCE_ID="${HONEYTRAP_INSTANCE_ID:-}"
SERVICE_NAME="${SERVICE_NAME:-internal-app}"
ENVIRONMENT="${ENVIRONMENT:-prod}"

# Helper functions
log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

log_pass() {
  echo -e "${GREEN}[PASS]${NC} $1"
}

log_fail() {
  echo -e "${RED}[FAIL]${NC} $1"
}

# Main validation function
main() {
  echo "========================================================"
  echo "AWS Secure Access Gateway Security Validation"
  echo "========================================================"
  echo ""

  local pass_count=0
  local fail_count=0

  # ====== Gateway Validations ======
  if [ -n "$GATEWAY_INSTANCE_ID" ]; then
    echo -e "${YELLOW}=== Gateway Security Checks ===${NC}"

    # Check 1: No public IP
    if validate_no_public_ip "$GATEWAY_INSTANCE_ID"; then
      ((pass_count++))
      log_pass "Gateway has no public IP"
    else
      ((fail_count++))
      log_fail "Gateway has a public IP (should be private)"
    fi

    # Check 2: Security group restrictions
    if validate_security_group "$GATEWAY_INSTANCE_ID"; then
      ((pass_count++))
      log_pass "Gateway security group restricts egress correctly"
    else
      ((fail_count++))
      log_fail "Gateway security group allows unrestricted egress"
    fi

    # Check 3: IMDSv2 required
    if validate_imdsv2 "$GATEWAY_INSTANCE_ID"; then
      ((pass_count++))
      log_pass "Gateway requires IMDSv2"
    else
      ((fail_count++))
      log_fail "Gateway doesn't require IMDSv2"
    fi

    # Check 4: Root volume encrypted
    if validate_encrypted_volume "$GATEWAY_INSTANCE_ID"; then
      ((pass_count++))
      log_pass "Gateway root volume is encrypted"
    else
      ((fail_count++))
      log_fail "Gateway root volume is NOT encrypted"
    fi

    # Check 5: IAM role has SSM permission
    if validate_iam_role_ssm "$GATEWAY_INSTANCE_ID"; then
      ((pass_count++))
      log_pass "Gateway IAM role has SSM policy"
    else
      ((fail_count++))
      log_fail "Gateway IAM role missing SSM policy"
    fi

    echo ""
  fi

  # ====== Honeytrap Validations ======
  if [ -n "$HONEYTRAP_INSTANCE_ID" ]; then
    echo -e "${YELLOW}=== Honeytrap Security Checks ===${NC}"

    # Check 1: No public IP
    if validate_no_public_ip "$HONEYTRAP_INSTANCE_ID"; then
      ((pass_count++))
      log_pass "Honeytrap has no public IP"
    else
      ((fail_count++))
      log_fail "Honeytrap has a public IP (should be private)"
    fi

    # Check 2: Restricted security group
    if validate_honeytrap_sg_egress "$HONEYTRAP_INSTANCE_ID"; then
      ((pass_count++))
      log_pass "Honeytrap security group restricts egress"
    else
      ((fail_count++))
      log_fail "Honeytrap security group allows unrestricted egress"
    fi

    # Check 3: Minimal IAM permissions
    if validate_honeytrap_iam "$HONEYTRAP_INSTANCE_ID"; then
      ((pass_count++))
      log_pass "Honeytrap IAM role has minimal permissions"
    else
      ((fail_count++))
      log_fail "Honeytrap IAM role has excessive permissions"
    fi

    # Check 4: Auth disabled in config
    if validate_honeytrap_auth_disabled "$HONEYTRAP_INSTANCE_ID"; then
      ((pass_count++))
      log_pass "Honeytrap authentication is disabled"
    else
      ((fail_count++))
      log_fail "Honeytrap authentication is NOT disabled"
    fi

    # Check 5: No successful authentications
    if validate_honeytrap_no_successful_auth "$HONEYTRAP_INSTANCE_ID"; then
      ((pass_count++))
      log_pass "Honeytrap has recorded zero successful authentications"
    else
      ((fail_count++))
      log_fail "Honeytrap has successful authentications (critical!)"
    fi

    echo ""
  fi

  # ====== Kubernetes Validations ======
  echo -e "${YELLOW}=== Kubernetes Security Checks ===${NC}"

  # Check 1: NetworkPolicy enabled
  if validate_networkpolicy_enabled; then
    ((pass_count++))
    log_pass "Kubernetes NetworkPolicy is enabled"
  else
    ((fail_count++))
    log_fail "Kubernetes NetworkPolicy is NOT enabled"
  fi

  # Check 2: Honeytrap NetworkPolicy isolation
  if validate_honeytrap_networkpolicy; then
    ((pass_count++))
    log_pass "Honeytrap NetworkPolicy isolation is configured"
  else
    ((fail_count++))
    log_fail "Honeytrap NetworkPolicy isolation is missing"
  fi

  echo ""

  # ====== Summary ======
  echo "========================================================"
  echo "Validation Summary"
  echo "========================================================"
  echo -e "Passed: ${GREEN}${pass_count}${NC}"
  echo -e "Failed: ${RED}${fail_count}${NC}"
  echo ""

  if [ $fail_count -eq 0 ]; then
    log_pass "All security validations passed!"
    return 0
  else
    log_error "Some security validations failed. Please review above."
    return 1
  fi
}

# Validation functions

validate_no_public_ip() {
  local instance_id=$1
  local public_ip=$(aws ec2 describe-instances \
    --instance-ids "$instance_id" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text 2>/dev/null || echo "None")
  
  if [ "$public_ip" = "None" ] || [ -z "$public_ip" ]; then
    return 0
  fi
  return 1
}

validate_security_group() {
  local instance_id=$1
  local sg_id=$(aws ec2 describe-instances \
    --instance-ids "$instance_id" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' \
    --output text)
  
  # Check egress rules don't allow all traffic (0.0.0.0/0)
  local all_traffic=$(aws ec2 describe-security-groups \
    --group-ids "$sg_id" \
    --region "$REGION" \
    --query 'SecurityGroups[0].IpPermissionsEgress[?IpRanges[?CidrIp==`0.0.0.0/0`]]' \
    --output text)
  
  if [ -z "$all_traffic" ]; then
    return 0
  fi
  return 1
}

validate_imdsv2() {
  local instance_id=$1
  local metadata_options=$(aws ec2 describe-instances \
    --instance-ids "$instance_id" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].MetadataOptions.HttpTokens' \
    --output text)
  
  if [ "$metadata_options" = "required" ]; then
    return 0
  fi
  return 1
}

validate_encrypted_volume() {
  local instance_id=$1
  local volume_id=$(aws ec2 describe-instances \
    --instance-ids "$instance_id" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
    --output text)
  
  local encrypted=$(aws ec2 describe-volumes \
    --volume-ids "$volume_id" \
    --region "$REGION" \
    --query 'Volumes[0].Encrypted' \
    --output text)
  
  if [ "$encrypted" = "True" ]; then
    return 0
  fi
  return 1
}

validate_iam_role_ssm() {
  local instance_id=$1
  local role_name=$(aws ec2 describe-instances \
    --instance-ids "$instance_id" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' \
    --output text | sed 's/.*\///')
  
  if [ -z "$role_name" ] || [ "$role_name" = "None" ]; then
    return 1
  fi
  
  # Check for SSM policy
  aws iam get-role-policy --role-name "$role_name" \
    --policy-name "*ssm*" >/dev/null 2>&1 && return 0
  
  # Alternative: check for managed policies
  aws iam list-attached-role-policies --role-name "$role_name" \
    --query 'AttachedPolicies[?PolicyName==`AmazonSSMManagedInstanceCore`]' \
    --output text | grep -q "AmazonSSM" && return 0
  
  return 1
}

validate_honeytrap_sg_egress() {
  local instance_id=$1
  local sg_id=$(aws ec2 describe-instances \
    --instance-ids "$instance_id" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' \
    --output text)
  
  # Check that honeytrap doesn't allow outbound access to 0.0.0.0/0 on most ports
  # Should only allow 443 (HTTPS) to VPC CIDR and 53 (DNS)
  local rules=$(aws ec2 describe-security-groups \
    --group-ids "$sg_id" \
    --region "$REGION" \
    --query 'SecurityGroups[0].IpPermissionsEgress[?IpRanges[?CidrIp==`0.0.0.0/0`]].FromPort' \
    --output text)
  
  # Should be empty or only contain specific ports
  if [ -z "$rules" ]; then
    return 0
  fi
  return 1
}

validate_honeytrap_iam() {
  local instance_id=$1
  local role_name=$(aws ec2 describe-instances \
    --instance-ids "$instance_id" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' \
    --output text | sed 's/.*\///')
  
  if [ -z "$role_name" ] || [ "$role_name" = "None" ]; then
    return 1
  fi
  
  # Check for dangerous permissions
  local policies=$(aws iam list-role-policies --role-name "$role_name" \
    --query 'PolicyNames[*]' --output text)
  
  for policy in $policies; do
    local policy_doc=$(aws iam get-role-policy --role-name "$role_name" \
      --policy-name "$policy" --query 'RolePolicy.PolicyDocument' --output json)
    
    # Check for EC2:*, S3:*, etc.
    if echo "$policy_doc" | grep -qE '"Action".*"\*"' || \
       echo "$policy_doc" | grep -qE '"Action".*"(ec2|s3|iam|dynamodb):.*\*"'; then
      return 1
    fi
  done
  
  return 0
}

validate_honeytrap_auth_disabled() {
  local instance_id=$1
  
  # Connect to honeytrap and check config
  log_info "Checking Honeytrap configuration..."
  aws ssm start-session --target "$instance_id" --region "$REGION" \
    --document-name AWS-StartInteractiveCommand \
    --parameters command="grep -A 2 '\[auth\]' /etc/honeytrap/config.toml" \
    2>/dev/null | grep -q "enabled = false" && return 0
  
  return 1
}

validate_honeytrap_no_successful_auth() {
  local instance_id=$1
  local log_group="/aws/honeytrap/${SERVICE_NAME}/${ENVIRONMENT}"
  
  # Query for successful authentications
  local auth_success=$(aws logs filter-log-events \
    --log-group-name "$log_group" \
    --filter-pattern "authentication_success" \
    --region "$REGION" \
    --query 'events[*].message' \
    --output text 2>/dev/null)
  
  if [ -z "$auth_success" ]; then
    return 0
  fi
  return 1
}

validate_networkpolicy_enabled() {
  local policies=$(kubectl get networkpolicies -A 2>/dev/null || echo "")
  
  if [ -n "$policies" ]; then
    return 0
  fi
  return 1
}

validate_honeytrap_networkpolicy() {
  local policy=$(kubectl get networkpolicy -n access-gateway \
    -o name 2>/dev/null | grep honeytrap)
  
  if [ -n "$policy" ]; then
    return 0
  fi
  return 1
}

# Run main
main "$@"
