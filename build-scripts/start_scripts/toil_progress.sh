#!/usr/bin/env bash

set -e


TMP_DIR=${1:-"/mnt/cache"}
DAG_ID=$2
RUN_ID=$3
# total steps is a couple more than actual so that final step processing doesn't cause progress to sit at 100%
TOTAL_STEPS=${4:-"1"}
TOTAL_STEPS=$(($TOTAL_STEPS + 3))

NJS_CLIENT_PORT=${5:-"3069"}

SEARCH_DIR="${TMP_DIR}/${DAG_ID}_${RUN_ID}/jobstore/stats"

# echo "directory for getting number of jobs run/running: $SEARCH_DIR"
# echo "number of total steps (-1): $TOTAL_STEPS"

sendProgressReport() {
    progress=$1
    PAYLOAD="{\"payload\":{\"dag_id\": \"${DAG_ID}\", \"run_id\": \"${RUN_ID}\", \"state\": \"\", \"progress\": $progress, \"error\": \"\", \"statistics\": \"\", \"logs\": \"\"}}"
    # echo "send payload: $PAYLOAD"
    curl -X POST http://localhost:${NJS_CLIENT_PORT}/airflow/progress -H "Content-Type: application/json" -d "${PAYLOAD}"
}

elapsed=0
delay=$((3 * 60)) # 3 minutes
timeout=$(( 8 * 60 * 60 )) # 8 hours
lastProgress=0
# success=0

# wait a couple seconds for toil to set stuff up with slurm
sleep 5

while true; do
    {
        # get current number of stpes processed by listing in column and counting columns
        stepNum=$(ls -1 $SEARCH_DIR | wc -l)
        # remove leading whitespace so stepNum is an actual number (if dir doesn't exist, will be 0)
        stepNum=$(($stepNum))

        # echo "number of current steps: $stepNum"
        # echo "max steps: $TOTAL_STEPS"

        # stop reporting if sample close to finished
        # if [ "$stepNum" -lt $(expr "$TOTAL_STEPS" - 1) ]
        # then 
            percentage=$( expr 100 '*' "$stepNum" / "$TOTAL_STEPS" )
            if [ "$percentage" -gt "$lastProgress" ]
            then 
                # echo "would report with progress of $percentage"
                sendProgressReport $percentage
            else
                echo "would NOT report anything"
            fi

            lastProgress=$percentage

            # manually add "steps" to test new progress steps
            # touch "$SEARCH_DIR/$percentage.cwl"
        # else
        #     echo "sample is 1 step from finished, report nothing and end progress watching"
        #     break
        # fi
    } || {
        echo "failed to check searchdir somehow. retry after delay"
    }
    if [ "$elapsed" -ge "$timeout" ]; then
        break
    fi 
    sleep "$delay"
    elapsed=$(( elapsed + delay ))
done
echo "watching progress reports on dir $SEARCH_DIR finished after $elapsed seconds"
