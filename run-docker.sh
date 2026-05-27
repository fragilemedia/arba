# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

usage() {
    echo "Usage: $0 -p <project> -d <dataset> -t <tagging_enabled> -l <logger_type>"
    exit 1
}
WORKFLOW=/app/workflow-config.yaml
LOG_NAME=arba

while getopts "a:c:p:d:t:w:l:" opt; do
    case $opt in
        a) ACCOUNT="$OPTARG" ;;
        c) ADS_CONFIG="$OPTARG" ;;
        p) BQ_PROJECT="$OPTARG" ;;
        d) BQ_DATASET="$OPTARG" ;;
        t) TAGGING_ENABLED="$OPTARG" ;;
        w) WORKFLOW="$OPTARG" ;;
        l) LOGGER="$OPTARG" ;;
        \?) echo "Invalid option: -$OPTARG" >&2; usage ;;
        :) echo "Option -$OPTARG requires an argument." >&2; usage ;;
    esac
done

if [ -z "$LOGGER" ]; then
  LOGGER='local'
fi
if [ -z "$START_DATE" ]; then
  START_DATE=:YYYYMMDD-31
fi

if [ -z "$END_DATE" ]; then
  END_DATE=:YYYYMMDD-1
fi
if [ -z "$MIN_COST_SHARE" ]; then
  MIN_COST_SHARE=80
fi
if [ -z "$BQ_PROJECT" ]; then
  BQ_PROJECT=$GOOGLE_CLOUD_PROJECT
fi
# Fragile patch: respect explicit TAGGING_ENABLED value (0 or 1), default to 0 if unset.
# Original upstream logic coerced any value to 1, which prevented Phase 1 deploys
# without AI from honoring TAGGING_ENABLED=0 env var.
if [ -z "$TAGGING_ENABLED" ]; then
  TAGGING_ENABLED=0
fi

run_bq() {
  local account=$1
  local project=$2
  local dataset=$3
  if [ -z "$dataset" ]; then
    local arba_dataset='arba'
  else
    local arba_dataset=${dataset}
  fi

  # Step 1: Always — fetch Google Ads data
  garf -w $WORKFLOW \
    --workflow-include googleads \
    --logger $LOGGER --log-name $LOG_NAME \
    --source.account=$account \
    --source.path-to-config=$ADS_CONFIG \
    --macro.start_date=$START_DATE --macro.end_date=$END_DATE \
    --output bq \
    --bq.project=$project --bq.dataset=${arba_dataset}

  # Step 2: AI LP scoring — ONLY if TAGGING_ENABLED (Fragile Phase 1 patch)
  if [[ $TAGGING_ENABLED -eq 1 ]]; then
    cd scripts
    python landings_score.py --dataset=${arba_dataset} \
      --log-name=$LOG_NAME --logger-type $LOGGER
    cd ..
  fi

  # Step 3: Always — create empty AI table placeholders + bq_input view
  garf -w $WORKFLOW \
    --workflow-include empty_bq,bq_input \
    --logger $LOGGER --log-name $LOG_NAME \
    --macro.dataset=${arba_dataset} --macro.target_dataset=${arba_dataset} \
    --source.project=$project

  # Step 4: AI USP/CTA tagging — ONLY if TAGGING_ENABLED (Fragile Phase 1 patch)
  if [[ $TAGGING_ENABLED -eq 1 ]]; then
    garf -w $WORKFLOW \
      --workflow-include tagging \
      --logger $LOGGER --log-name $LOG_NAME \
      --macro.dataset=${arba_dataset} --macro.target_dataset=${arba_dataset} \
      --macro.cost_share=$MIN_COST_SHARE \
      --output bq \
      --bq.project=$project --bq.dataset=${arba_dataset} \
      --source.project=$project
  fi

  # Step 5: Always — final BQ transforms
  garf -w $WORKFLOW \
    --workflow-skip googleads,bq_input,empty_bq,tagging \
    --logger $LOGGER --log-name $LOG_NAME \
    --macro.dataset=${arba_dataset} --macro.target_dataset=${arba_dataset} \
    --source.project=$project
}
run_bq $ACCOUNT $BQ_PROJECT $BQ_DATASET
