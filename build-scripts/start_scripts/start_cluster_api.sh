#!/bin/bash 

## using absolute paths

# will have /PROJ_ID/SAMP_ID appended for each sample run given
OUTPUT_DIR="${OUTPUT_DIR:="/home/scidap/scidap/projects"}"
# will use 'run_toil.sh' script in this dir (should be satellite bin)
SCRIPT_DIR="${SCRIPT_DIR:="/home/scidap/satellite/satellite/bin"}" 
TMP_TOIL_DIR="${TMP_TOIL_DIR:="/mnt/cache/TOIL_TMP_DIR"}"
# a better default path needs to be established
ENV_FILE_PATH="${ENV_FILE_PATH:="/path/to/temporary/myenv/bin/activate"}"
SINGULARITY_TMP_DIR="${SINGULARITY_TMP_DIR:="/mnt/cache/SINGULARITY_TMP_DIR"}"
NJS_CLIENT_PORT="${NJS_CLIENT_PORT:="3069"}"
CWL_SINGULARITY_DIR="${CWL_SINGULARITY_DIR:="/mnt/cache/SINGULARITY_TMP_DIR"}"
BATCH_SYSTEM_TOIL="${BATCH_SYSTEM_TOIL:="lsf"}"
NUM_CPUS="${NUM_CPUS:="8"}"
MAX_MEM="${MAX_MEM:="68719476736"}"
SATELLITE_ROOT="${SATELLITE_ROOT:="/home/scidap"}"
## above is for the sed line in case satellite not installed at /home/scidap

echo "Starting Cluster API for cwl-toil"
start-cluster-api $OUTPUT_DIR $SCRIPT_DIR $TMP_TOIL_DIR $ENV_FILE_PATH $BATCH_SYSTEM_TOIL $NJS_CLIENT_PORT $SINGULARITY_TMP_DIR $CWL_SINGULARITY_DIR $NUM_CPUS $MAX_MEM
# $SATELLITE_ROOT