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

  ERROR_REPORT=$OUTDIR/error_report.txt
  ERROR_MSG=$OUTDIR/error_msg.txt

  echo "" > $ERROR_MSG
  echo "" > $ERROR_REPORT

  # find all "error_msg.txt" files in TMPDIR
  # concat to outdir
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

  # find all toil errors and include them in msg (add to report for each one found)
  # the sort is to somewhat order the files by step
  find $TMPDIR -name "failed*json*.log" | sort | while read fname; do
    # get step failure name from file name
    tmp=${fname#*.json.}
    stepName=${tmp%%.*}  ## greedy match to get only step name

    # if it includes "_toil_" then it is a log about creating that step (from dispatcher)
    # if it doesn't, its a log from that step actually running (from step itself)
    if [[ "$fname" == *"_toil_"* ]]; then
      echo "# collected error log from job-dispatcher for step $stepName  " >> $ERROR_MSG
    else
      echo "# collected error log from step $stepName  " >> $ERROR_MSG
    fi

    # output log into msg, and format content as test with line breaks (to preserve sizing)
    echo '<div style="white-space: pre-wrap;">' >> $ERROR_MSG
    awk '{print $0 "<br>"}' $fname >> $ERROR_MSG
    echo '</div>' >> $ERROR_MSG
    echo "--------------------------  " >> $ERROR_MSG
  done

  # create results.json
  ER_FILESIZE=$(du -sb "$ERROR_REPORT" | cut -f1)
  # #$(stat -c%s "$ERROR_REPORT")
  EM_FILESIZE=$(du -sb "$ERROR_MSG" | cut -f1)
  # #$(stat -c%s "$ERROR_MSG")

  # also include sha?

  # reformat locatoins as toil would
  ERROR_MSG="file://$ERROR_MSG"
  ERROR_REPORT="file://$ERROR_REPORT"
  
  # ERROR_RESULTS=$( jq -n \
    #   --arg er "$ERROR_REPORT" \
    #   --arg em "$ERROR_MSG" \
    #   --arg e true \
    #   '{error_report: $er, error_msg: $em, scidap_error: $e}' )  
  ERROR_RESULTS=$( jq -n \
    --arg er "$ERROR_REPORT" \
    --arg em "$ERROR_MSG" \
    --arg ems "$EM_FILESIZE" \
    --arg ers "$ER_FILESIZE" \
    --arg e true \
    '{scidap_error: $e, error_report: {class: "file", location: $er, nameext: ".txt", nameroot: "error_report", basename: "error_report.txt", size: $ers}, error_msg: {class: "file", location: $em, nameext: ".txt", nameroot: "error_msg", basename: "error_msg.txt", size: $ems} }' )
  echo "$ERROR_RESULTS" > $OUTDIR/results.json


  PAYLOAD="{\"payload\":{\"dag_id\": \"${DAG_ID}\", \"run_id\": \"${RUN_ID}\", \"results\": $ERROR_RESULTS}}"

  ## if size of EITHER files > 10         (was >2) (was BOTH)
  if [ $EM_FILESIZE -gt 10 ] || [ $ER_FILESIZE -gt 10 ]; then 
    echo $PAYLOAD > "${OUTDIR}/payload.json"
    echo "payload for new error report: $PAYLOAD"
    curl -X POST http://localhost:${NJS_CLIENT_PORT}/airflow/results -H "Content-Type: application/json" -d @"${OUTDIR}/payload.json"
  else 
  # else, send error report

    # send report
    echo "Sending workflow execution error"
    PAYLOAD="{\"payload\":{\"dag_id\": \"${DAG_ID}\", \"run_id\": \"${RUN_ID}\", \"state\": \"failed\", \"progress\": 0, \"error\": \"failed\", \"statistics\": \"\", \"logs\": \"\"}}"
    echo $PAYLOAD > "${OUTDIR}/payload.json"
    # echo $PAYLOAD
    echo "payload for normal error: $PAYLOAD"
    curl -X POST http://localhost:${NJS_CLIENT_PORT}/airflow/progress -H "Content-Type: application/json" -d @"${OUTDIR}/payload.json" #-d "${PAYLOAD}"
  fi
  



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
    echo "payload: $PAYLOAD"
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
  
  echo "payload: $PAYLOAD"
  curl -X POST http://localhost:${NJS_CLIENT_PORT}/airflow/results -H "Content-Type: application/json" -d @"${OUTDIR}/payload.json"

  echo "Cleaning temporary directory ${TMPDIR}/${DAG_ID}_${RUN_ID}"
  rm -rf "${TMPDIR}"
  pkill -P $progressPID
  exit 0
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
