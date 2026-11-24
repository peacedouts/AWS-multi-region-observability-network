#!/usr/bin/env bash
# Post-apply isolation test using VPC Reachability Analyzer.
#   POSITIVE: hub central-API ENI -> spoke regional-gateway ALB ENI on 443 must be reachable
#   NEGATIVE: hub central-API ENI -> spoke Aurora ENI on 5432 must NOT be reachable
# Isolation is tested on every apply, not assumed.
#
# Cross-account analysis needs Reachability Analyzer's Organizations
# integration (delegated admin in the network account); paths are created there.
set -euo pipefail

analyze() { # source_eni dest_eni port expect(true|false) label
  local path_id analysis_id status reachable
  path_id=$(aws ec2 create-network-insights-path --source "$1" --destination "$2" \
            --destination-port "$3" --protocol tcp --query NetworkInsightsPath.NetworkInsightsPathId --output text)
  analysis_id=$(aws ec2 start-network-insights-analysis --network-insights-path-id "$path_id" \
            --query NetworkInsightsAnalysis.NetworkInsightsAnalysisId --output text)
  for _ in $(seq 1 30); do
    status=$(aws ec2 describe-network-insights-analyses --network-insights-analysis-ids "$analysis_id" \
             --query 'NetworkInsightsAnalyses[0].Status' --output text)
    [ "$status" != "running" ] && break
    sleep 5
  done
  reachable=$(aws ec2 describe-network-insights-analyses --network-insights-analysis-ids "$analysis_id" \
              --query 'NetworkInsightsAnalyses[0].NetworkPathFound' --output text | tr 'A-Z' 'a-z')
  if [ "$reachable" = "$4" ]; then echo "PASS  $5 (reachable=$reachable)"; else echo "FAIL  $5 (reachable=$reachable, expected $4)"; return 1; fi
}

# ENI IDs are resolved by tag in the real pipeline; passed in here for clarity.
: "${HUB_ENI:?}" "${GATEWAY_ALB_ENI:?}" "${AURORA_ENI:?}"
rc=0
analyze "$HUB_ENI" "$GATEWAY_ALB_ENI" 443  true  "hub -> regional gateway :443" || rc=1
analyze "$HUB_ENI" "$AURORA_ENI"      5432 false "hub -> regional Aurora :5432" || rc=1
exit $rc
