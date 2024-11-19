#!/bin/bash
set -e

# {cwl_filename} {job_filename} {output_folder} {tmp_output_dir} 
WORKFLOW=$1
JOB=$2
OUTDIR=$3
TMPDIR=$4 # must be accessible by all nodes /data/barskilab/michael/toil_temp
# {dag_id} {run_id} {toil_env_file} 
DAG_ID=$5
RUN_ID=$6
TOIL_ENV_FILE=$7
# {batch_system} {njs_port} {singularity_tmp_dir} {cwl_singularity_dir} {num_cpu}
BATCH_SYSTEM=$8
NJS_CLIENT_PORT=${9:-"3069"}
SINGULARITY_TMP_DIR=$10
CWL_SINGULARITY_CACHE=${11:-"${SINGULARITY_TMP_DIR}"}
SYSTEM_ROOT=${12:-"/home/scidap_satellite/scidap"}
CPU=${13:-"6"}
MEMORY=${14:-"68719476736"}
TOTAL_STEPS=${15:-"2"}
SCRIPT_DIR=${16:-"/home/scidap_satellite/satellite/satellite/bin"}

JOBSTORE="${TMPDIR}/${DAG_ID}_${RUN_ID}/jobstore"
LOGS="${TMPDIR}/${DAG_ID}_${RUN_ID}/logs"

WORKFLOW_TABLE="$SCRIPT_DIR/workflow_req_table.csv"

    
# # start progress script in background and kill with this
bash $SCRIPT_DIR/toil_progress.sh $TMPDIR $DAG_ID $RUN_ID $TOTAL_STEPS $NJS_CLIENT_PORT &
progressPID=$!

list_descendants ()
{
  local children=$(ps -o pid= --ppid "$1")

  for pid in $children
  do
    list_descendants "$pid"
  done

  echo "$children"
}

cleanup()
{
  EXIT_CODE=$?
  echo "Catching workflow error and getting error msg/report"

  # TMPDIR="/Users/scrowley/Desktop/REPOS/personal_scripts/TMP_TEST_DIR"
  # OUTDIR="/Users/scrowley/Desktop/REPOS/personal_scripts/TMP_OUT_DIR"

  ERROR_REPORT=$OUTDIR/error_report.txt
  ERROR_MSG=$OUTDIR/error_msg.txt

  # find all "error_msg.txt" files in TMPDIR
  # concat to outdir
  # for i in "$TMPDIR/**/error_msg.txt"; do # Whitespace-safe and recursive
  #     # process "$i"
  #     echo "$i"
  # done
  # find "$TMPDIR" -name "error_msg.txt" -exec process {} \;
  # find $TMPDIR -name error_msg.txt -print0 | xargs -0 process
  find $TMPDIR -name "error_msg.txt" | while read fname; do
      # echo "$fname"
      echo $(cat $fname) >> $ERROR_MSG
      echo "--------------------------" >> $ERROR_MSG
  done


  # find all "error_report.txt" files in TMPDIR
  # concat to outdir
  find $TMPDIR -name "error_report.txt" | while read fname; do
      # echo "$fname"
      echo $(cat $fname) >> $ERROR_REPORT
      echo "--------------------------" >> $ERROR_REPORT
  done



  # create results.json

  ERROR_RESULTS=$( jq -n \
                    --arg er "$ERROR_REPORT" \
                    --arg em "$ERROR_MSG" \
                    --arg e true \
                    '{error_report: $er, error_msg: $em, scidap_error: $e}' )
  echo "$ERROR_RESULTS" > $OUTDIR/results.json


  PAYLOAD="{\"payload\":{\"dag_id\": \"${DAG_ID}\", \"run_id\": \"${RUN_ID}\", \"results\": $ERROR_RESULTS}}"
  # send report
  # echo "Sending workflow execution error"
  # PAYLOAD="{\"payload\":{\"dag_id\": \"${DAG_ID}\", \"run_id\": \"${RUN_ID}\", \"state\": \"failed\", \"progress\": 0, \"error\": \"failed\", \"statistics\": \"\", \"logs\": \"\"}}"
  # echo $PAYLOAD
  # curl -X POST http://localhost:${NJS_CLIENT_PORT}/airflow/progress -H "Content-Type: application/json" -d "${PAYLOAD}"


  pkill -P $progressPID
  #kill $(list_descendants $$)
  exit ${EXIT_CODE}
}

trap cleanup SIGINT SIGTERM SIGKILL ERR

# remove "format" field from files in cwl
sed -i '/\"format\": \[/,/]/ d; /^$/d' $WORKFLOW
sed -i '/"format": /d' $WORKFLOW


runSingleMode()
{
    trap cleanup SIGINT SIGTERM SIGKILL ERR
    source $TOIL_ENV_FILE
    mkdir -p ${OUTDIR} ${LOGS}
    rm -rf ${JOBSTORE}
    export TMPDIR="${TMPDIR}/${DAG_ID}_${RUN_ID}"
    export SINGULARITY_TMPDIR=$SINGULARITY_TMP_DIR
    export TOIL_LSF_ARGS="-W 48:00"

    echo "Starting workflow execution"
    PAYLOAD="{\"payload\":{\"dag_id\": \"${DAG_ID}\", \"run_id\": \"${RUN_ID}\", \"state\": \"Sent to Cluster\", \"progress\": 8, \"error\": \"\", \"statistics\": \"\", \"logs\": \"\"}}"
    echo $PAYLOAD
    curl -X POST http://localhost:${NJS_CLIENT_PORT}/airflow/progress -H "Content-Type: application/json" -d "${PAYLOAD}"


    toil-cwl-runner \
    --logDebug \
    --stats \
    --bypass-file-store \
    --batchSystem single_machine \
    --retryCount 0 \
    --disableCaching \
    --defaultMemory ${MEMORY} \
    --defaultCores ${CPU} \
    --jobStore "${JOBSTORE}" \
    --writeLogs ${LOGS} \
    --outdir ${OUTDIR} ${WORKFLOW} ${JOB} > ${OUTDIR}/results_full.json
    toil stats ${JOBSTORE} > ${OUTDIR}/stats.txt
    cat ${OUTDIR}/results_full.json | ${SCRIPT_DIR}/jq 'walk(if type == "object" then with_entries(select(.key | test("listing") | not)) else . end)' > ${OUTDIR}/results.json
    
    RESULTS=`cat ${OUTDIR}/results.json`
    PAYLOAD="{\"payload\":{\"dag_id\": \"${DAG_ID}\", \"run_id\": \"${RUN_ID}\", \"results\": $RESULTS}}"
    echo $PAYLOAD > "${OUTDIR}/payload.json"
    echo "Sending workflow execution results from ${OUTDIR}/payload.json"
    curl -X POST http://localhost:${NJS_CLIENT_PORT}/airflow/results -H "Content-Type: application/json" -d @"${OUTDIR}/payload.json"

    echo "Cleaning temporary directory ${TMPDIR}/${DAG_ID}_${RUN_ID}"
    rm -rf "${TMPDIR}"
    pkill -P $progressPID
}

runClusterMode(){
  trap cleanup SIGINT SIGTERM SIGKILL ERR
  
  replacementStr="\"location\": \"file://$SYSTEM_ROOT"
  # echo $replacementStr
  #sed -i "s|\"location\": \"file:///mnt/scidap-storage/PUBLIC_SATELLITE/|$replacementStr|g" $JOB
  sed -i "s|$replacementStr|\"location\": \"file:///mnt/scidap-storage/|g" $JOB
  
  source $TOIL_ENV_FILE
  mkdir -p ${OUTDIR} ${LOGS}
  rm -rf ${JOBSTORE}
  export TMPDIR="${TMPDIR}/${DAG_ID}_${RUN_ID}"
  export SINGULARITY_TMPDIR=$SINGULARITY_TMP_DIR
  export TOIL_LSF_ARGS="-W 48:00"

  echo "Starting workflow execution"
  PAYLOAD="{\"payload\":{\"dag_id\": \"${DAG_ID}\", \"run_id\": \"${RUN_ID}\", \"state\": \"Sent to Cluster\", \"progress\": 8, \"error\": \"\", \"statistics\": \"\", \"logs\": \"\"}}"
  echo $PAYLOAD
  curl -X POST http://localhost:${NJS_CLIENT_PORT}/airflow/progress -H "Content-Type: application/json" -d "${PAYLOAD}"


  ## TODO: cpu/mem

  # LABEL=$(jq -r '.label' $WORKFLOW)
  # echo "label: ${LABEL}"
  # # LABEL_LINE=$(sed -n '/$LABEL/p' $WORKFLOW)
  # # LABEL_LINE=$(grep -n "${LABEL}" $WORKFLOW)
  # LABEL_LINE=$(grep -n "$LABEL" $WORKFLOW_TABLE)
  # # awk -v line='0 8 * * * Me echo "start working please"' '$0 == line {print "this is the line number", NR, "from", FILENAME}' a
  # echo "label line: $LABEL_LINE"

  # ## comma separate and get last entry
  # commaSepLine=()
  # tmpIFS=$IFS
  # IFS=$IFS,
  # for f in $LABEL_LINE; do commaSepLine+=($f); done
  # IFS=$tmpIFS
  # # get last entry
  # JOB_PRIO=${commaSepLine[${#commaSepLine[@]} - 1]} #${commaSepLine[-1]}
  # # strip other chars
  # JOB_PRIO=$(echo $JOB_PRIO | sed -e 's/\r//g')

  # case "$JOB_PRIO" in
  #   "high")
  #     MEMORY=122070 # 128Gb  #61035 64Gb
  #     CPU=12
  #     ;;
  #   "med")
  #     MEMORY=30517 # 32Gb
  #     CPU=4
  #     ;;
  #   "low")
  #     MEMORY=3814 # 2Gb
  #     CPU=1
  #     ;;
  #   *)
  #     MEMORY=30517  # 32Gb
  #     CPU=4
  #     ;;
  # esac

  MEMORY=30517  # 32Gb
  CPU=4
  echo "MEM: $MEMORY"
  echo "CPU: $CPU"
  echo "running toil with assigned cpu/mem"
  toil-cwl-runner \
    --logDebug \
    --stats \
    --bypass-file-store \
    --batchSystem slurm \
    --retryCount 0 \
    --disableCaching \
    --defaultMemory "${MEMORY}Mi" \
    --defaultCores "${CPU}.0" \
    --jobStore "${JOBSTORE}" \
    --writeLogs ${LOGS} \
    --outdir ${OUTDIR} ${WORKFLOW} ${JOB} > ${OUTDIR}/results_full.json

  # else
  #     echo "let toil parse"
  #     toil-cwl-runner \
  #       --logDebug \
  #       --stats \
  #       --bypass-file-store \
  #       --batchSystem slurm \
  #       --retryCount 0 \
  #       --disableCaching \
  #       --jobStore "${JOBSTORE}" \
  #       --writeLogs ${LOGS} \
  #       --outdir ${OUTDIR} ${WORKFLOW} ${JOB} > ${OUTDIR}/results_full.json
  # fi

  
  toil stats ${JOBSTORE} > ${OUTDIR}/stats.txt
  cat ${OUTDIR}/results_full.json | ${SCRIPT_DIR}/jq 'walk(if type == "object" then with_entries(select(.key | test("listing") | not)) else . end)' > ${OUTDIR}/results.json
  
  RESULTS=`cat ${OUTDIR}/results.json`
  PAYLOAD="{\"payload\":{\"dag_id\": \"${DAG_ID}\", \"run_id\": \"${RUN_ID}\", \"results\": $RESULTS}}"
  echo $PAYLOAD > "${OUTDIR}/payload.json"
  echo "Sending workflow execution results from ${OUTDIR}/payload.json"
  curl -X POST http://localhost:${NJS_CLIENT_PORT}/airflow/results -H "Content-Type: application/json" -d @"${OUTDIR}/payload.json"

  echo "Cleaning temporary directory ${TMPDIR}/${DAG_ID}_${RUN_ID}"
  rm -rf "${TMPDIR}"
  pkill -P $progressPID

}


runLsfClusterMode()
{
trap cleanup SIGINT SIGTERM SIGKILL ERR
replacementStr="\"location\": \"file://$SYSTEM_ROOT"
# echo $replacementStr
sed -i "s|\"location\": \"file:///scidap/|$replacementStr|g" $JOB


bsub -J "${DAG_ID}_${RUN_ID}" \
     -M 64000 \
     -W 48:00 \
     -n 4 \
     -R "rusage[mem=64000] span[hosts=1]" \
     -o "${OUTDIR}/stdout.txt" \
     -e "${OUTDIR}/stderr.txt" << EOL
module purge
module load nodejs jq anaconda3 singularity/3.7.0
source $TOIL_ENV_FILE
mkdir -p ${OUTDIR} ${LOGS}
rm -rf ${JOBSTORE}
export TMPDIR="${TMPDIR}/${DAG_ID}_${RUN_ID}"
export SINGULARITY_TMPDIR=$SINGULARITY_TMP_DIR
export CWL_SINGULARITY_CACHE=$CWL_SINGULARITY_CACHE
export TOIL_LSF_ARGS="-W 48:00"
toil-cwl-runner \
--logDebug \
--bypass-file-store \
--batchSystem lsf \
--singularity \
--retryCount 0 \
--clean always \
--disableCaching \
--defaultMemory ${MEMORY} \
--defaultCores ${CPU} \
--jobStore "${JOBSTORE}" \
--writeLogs ${LOGS} \
--outdir ${OUTDIR} ${WORKFLOW} ${JOB} | jq 'walk(if type == "object" then with_entries(select(.key | test("listing") | not)) else . end)' > ${OUTDIR}/results.json
EOL

# jq 'walk(if type == "object" then with_entries(select(.key | test("listing") | not)) else . end)'


bwait -w "started(${DAG_ID}_${RUN_ID})"
echo "Sending workflow execution progress"
PAYLOAD="{\"payload\":{\"dag_id\": \"${DAG_ID}\", \"run_id\": \"${RUN_ID}\", \"state\": \"Sent to Cluster\", \"progress\": 8, \"error\": \"\", \"statistics\": \"\", \"logs\": \"\"}}"
echo $PAYLOAD
curl -X POST http://localhost:${NJS_CLIENT_PORT}/airflow/progress -H "Content-Type: application/json" -d "${PAYLOAD}"

bwait -w "done(${DAG_ID}_${RUN_ID})"      # won't be caught by trap if job finished successfully

RESULTS=`cat ${OUTDIR}/results.json`
PAYLOAD="{\"payload\":{\"dag_id\": \"${DAG_ID}\", \"run_id\": \"${RUN_ID}\", \"results\": $RESULTS}}"
echo $PAYLOAD > "${OUTDIR}/payload.json"
echo "Sending workflow execution results from ${OUTDIR}/payload.json"
# kill $progressPID
curl -X POST http://localhost:${NJS_CLIENT_PORT}/airflow/results -H "Content-Type: application/json" -d @"${OUTDIR}/payload.json"

echo "Cleaning temporary directory ${TMPDIR}/${DAG_ID}_${RUN_ID}"
bsub -J "${DAG_ID}_${RUN_ID}_cleanup" \
     -M 16000 \
     -W 8:00 \
     -n 2 \
     -R "rusage[mem=16000] span[hosts=1]" \
     -o "${OUTDIR}/cleanup_stdout.txt" \
     -e "${OUTDIR}/cleanup_stderr.txt" << EOL
rm -rf "${TMPDIR}/${DAG_ID}_${RUN_ID}"
EOL
bwait -w "ended(${DAG_ID}_${RUN_ID}_cleanup)"
# waiting for singularity/toil to formally end before kill progress-process might result in progress sending back a percentage when it shouldnt have
pkill -P $progressPID
}

if [ "$BATCH_SYSTEM" = "slurm" ]
then
  runClusterMode
elif [ "$BATCH_SYSTEM" = "single_machine" ]
then
  runSingleMode
elif [ "$BATCH_SYSTEM" = "lsf" ]
then
  runLsfClusterMode
else 
  echo "BATCH SYSTEM not recognized. job not run"
  cleanup
fi
