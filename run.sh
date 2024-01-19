#!/bin/bash
set -xe
#Set Path to repo
export git_repo_working_dir=${WORK}/sites-and-stories-nlp

echo "TACC: job ${SLURM_JOB_ID} execution at: $(date)"
echo load cuda
module load cuda/12.0

# This file will be located in the directory mounted by the job.
SESSION_FILE=delete_me_to_end_session
touch $SESSION_FILE

# RUN JUPYTER SESSION IN BACKGROUND  -->  CAN STAY THE SAME
LOCAL_IPY_PORT=8888

# TAP Port
LOCAL_PORT=5902

NODE_HOSTNAME_PREFIX=$(hostname -s)   # Short Host Name  -->  name of compute node: c###-###
NODE_HOSTNAME_DOMAIN=$(hostname -d)   # DNS Name  -->  stampede2.tacc.utexas.edu
NODE_HOSTNAME_LONG=$(hostname -f)     # Fully Qualified Domain Name  -->  c###-###.stampede2.tacc.utexas.edu

echo "Checking if miniconda3 is installed..."
if [ ! -d "$WORK/miniconda3" ]; then
  echo "Miniconda not found in $WORK..."
  echo "Installing..."
  mkdir -p $WORK/miniconda3
  curl https://repo.anaconda.com/miniconda/Miniconda3-py311_23.10.0-1-Linux-x86_64.sh -o $WORK/miniconda3/miniconda.sh
  #The latest repo from miniconda does not install correctly. Use the prior one for the next month of so. Dec 19, 2023
#   curl https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -o $WORK/miniconda3/miniconda.sh
  bash $WORK/miniconda3/miniconda.sh -b -u -p $WORK/miniconda3
  rm -rf $WORK/miniconda3/miniconda.sh
  export PATH="$WORK/miniconda3/bin:$PATH"
  echo "Ensuring conda base environment is OFF..."
  conda config --set auto_activate_base false
else
  export PATH="$WORK/miniconda3/bin:$PATH"
fi

conda init bash
echo "Sourcing .bashrc..."
source ~/.bashrc
unset PYTHONPATH

echo "Initializing conda..."
conda info
## Path to the python environment where the jupyter notebook packages are installed
if [ ! -d "$git_repo_working_dir" ]; then
    echo "Env not found, downloading"
    git clone  https://github.com/In-For-Disaster-Analytics/sites-and-stories-nlp.git --branch jupyterenv $git_repo_working_dir
    # conda env create -n llm -f $git_repo_working_dir/.binder/environment.yml --force
#else
    # git -C $git_repo_working_dir pull origin jupyterenv
    # conda env update -n llm  -f $git_repo_working_dir/.binder/environment.yml --prune
fi

export TRANSFORMERS_CACHE="$git_repo_working_dir"


echo "TACC: running on node $NODE_HOSTNAME_PREFIX on $NODE_HOSTNAME_DOMAIN"

TAP_FUNCTIONS="/share/doc/slurm/tap_functions"
if [ -f ${TAP_FUNCTIONS} ]; then
    . ${TAP_FUNCTIONS}
else
    echo "TACC:"
    echo "TACC: ERROR - could not find TAP functions file: ${TAP_FUNCTIONS}"
    echo "TACC: ERROR - Please submit a consulting ticket at the TACC user portal"
    echo "TACC: ERROR - https://portal.tacc.utexas.edu/tacc-consulting/-/consult/tickets/create"
    echo "TACC:"
    echo "TACC: job $SLURM_JOB_ID execution finished at: $(date)"
    exit 1
fi

# Note: NotebookApp needs some work.
JUPYTER_SERVER_APP="ServerApp"
if [ ${JUPYTER_SERVER_APP} == "ServerApp" ]; then
    JUPYTER_BIN="jupyter-lab"
elif [ ${JUPYTER_SERVER_APP} == "NotebookApp" ]; then
    JUPYTER_BIN="jupyter-notebook"
fi
echo "JUPYTER_SERVER_APP is $JUPYTER_SERVER_APP"
echo "JUPYTER_BIN is $JUPYTER_BIN"

NB_SERVERDIR=$HOME/MyData/.jupyter

# make .jupyter dir for logs
mkdir -p ${NB_SERVERDIR}

mkdir -p ${HOME}/.tap # this should exist at this point, but just in case...
TAP_CERTFILE=${HOME}/.tap/.${SLURM_JOB_ID}

# bail if we cannot create a secure session
if [ ! -f ${TAP_CERTFILE} ]; then
    echo "TACC: ERROR - could not find TLS cert for secure session"
    echo "TACC: job ${SLURM_JOB_ID} execution finished at: $(date)"
    exit 1
fi

# bail if we cannot create a token for the session
TAP_TOKEN=$(tap_get_token)
if [ -z "${TAP_TOKEN}" ]; then
    echo "TACC: ERROR - could not generate token for jupyter session"
    echo "TACC: job ${SLURM_JOB_ID} execution finished at: $(date)"
    exit 1
fi
echo "TACC: using token ${TAP_TOKEN}"

# create the tap jupyter config if needed
TAP_JUPYTER_CONFIG="$NB_SERVERDIR/jupyter_config.py"

echo ${PWD}


cat <<- EOF > ${TAP_JUPYTER_CONFIG}
# Configuration file for TAP jupyter session
import ssl
c = get_config()
c.IPKernelApp.pylab = "inline"  # if you want plotting support always
c.${JUPYTER_SERVER_APP}.ip = "0.0.0.0"
c.${JUPYTER_SERVER_APP}.port = $LOCAL_PORT
c.${JUPYTER_SERVER_APP}.open_browser = False
c.${JUPYTER_SERVER_APP}.allow_origin = u"*"
c.${JUPYTER_SERVER_APP}.ssl_options = {"ssl_version": ssl.PROTOCOL_TLSv1_2}
c.${JUPYTER_SERVER_APP}.root_dir = "${NB_HOME}/work"
c.${JUPYTER_SERVER_APP}.preferred_dir = "${NB_HOME}/work"
c.IdentityProvider.token = "${TAP_TOKEN}"
c.MultiKernelManager.default_kernel_name = 'llm'
EOF

# launch jupyter
JUPYTER_LOGFILE=${NB_SERVERDIR}/${NODE_HOSTNAME_PREFIX}.log
touch $JUPYTER_LOGFILE

JUPYTER_ARGS="--certfile=$(cat ${TAP_CERTFILE}) --config=${TAP_JUPYTER_CONFIG}"
echo "TACC: using jupyter command: ${JUPYTER_BIN} ${JUPYTER_ARGS} &> ${JUPYTER_LOGFILE} &"
nohup ${JUPYTER_BIN} ${JUPYTER_ARGS} &> ${JUPYTER_LOGFILE} &

JUPYTER_PID=$!

LOGIN_PORT=$(tap_get_port)
echo "TACC: got login node jupyter port ${LOGIN_PORT}"

JUPYTER_URL="https://${NODE_HOSTNAME_DOMAIN}:${LOGIN_PORT}/?token=${TAP_TOKEN}"


# verify jupyter is up. if not, give one more try, then bail
if ! $(ps -fu ${USER} | grep ${JUPYTER_BIN} | grep -qv grep) ; then
    # sometimes jupyter has a bad day. give it another chance to be awesome.
    echo "TACC: first jupyter launch failed. Retrying..."
    nohup ${JUPYTER_BIN} ${JUPYTER_ARGS} &> ${JUPYTER_LOGFILE} &
fi

if ! $(ps -fu ${USER} | grep ${JUPYTER_BIN} | grep -qv grep) ; then
    # jupyter will not be working today. sadness.
    echo "TACC: ERROR - jupyter failed to launch"
    echo "TACC: ERROR - this is often due to an issue in your python or conda environment"
    echo "TACC: ERROR - jupyter logfile contents:"
    cat ${JUPYTER_LOGFILE}
    echo "TACC: job ${SLURM_JOB_ID} execution finished at: $(date)"
    exit 1
fi



# Port forwarding is set up for the four login nodes.
#
#   f: Requests ssh to go to background just before command execution.
#      Used if ssh asks for passwords but the user wants it in the background. Implies -n too.
#   g: Allows remote hosts to connect to local forwarded ports
#   N: Do not execute a remote command. Useful for just forwarding ports.
#   R: Connections to given TCP port/Unix socket on remote (server) host forwarded to local side.
#
# Create a reverse tunnel port from the compute node to the login nodes.
# Make one tunnel for each login so the user can just connect to stampede.tacc.utexas.edu.
for i in $(seq 2); do
    ssh -q -f -g -N -R ${LOGIN_PORT}:${NODE_HOSTNAME_PREFIX}:${LOCAL_PORT} login${i}
done
if [ $(ps -fu ${USER} | grep ssh | grep login | grep -vc grep) != 2 ]; then
    # jupyter will not be working today. sadness.
    echo "TACC: ERROR - ssh tunnels failed to launch"
    echo "TACC: ERROR - this is often due to an issue with your ssh keys"
    echo "TACC: ERROR - undo any recent mods in ${HOME}/.ssh"
    echo "TACC: ERROR - or submit a TACC consulting ticket with this error"
    echo "TACC: job ${SLURM_JOB_ID} execution finished at: $(date)"
    exit 1
fi

INTERACTIVE_WEBHOOK_URL="${_webhook_base_url}"

# Wait a few seconds for jupyter to boot up and send webhook callback url for job ready notification.
# Notification is sent to _INTERACTIVE_WEBHOOK_URL, e.g. https://3dem.org/webhooks/interactive/
(
    sleep 5 &&
    curl -k --data "event_type=interactive_session_ready&address=${JUPYTER_URL}&owner=${_tapisJobOwner}&job_uuid=${_tapisJobUUID}" "${_INTERACTIVE_WEBHOOK_URL}" &
) &

# Delete the session file to kill the job.
echo $NODE_HOSTNAME_LONG $IPYTHON_PID > $SESSION_FILE

### Create env
if { conda env list | grep 'llm'; } >/dev/null 2>&1; then
    conda activate llm
    conda env update --file $git_repo_working_dir/.binder/environment.yml --prune
    pip install --no-cache-dir -r $git_repo_working_dir/.binder/requirements.txt
else
    conda env create -n llm -f $git_repo_working_dir/.binder/environment.yml --force
    conda activate llm
    pip install --no-cache-dir -r $git_repo_working_dir/.binder/requirements.txt
    python -m ipykernel install --user --name llm --display-name "Python (llm)"
fi
echo "JUPYTER_URL is"
echo  $JUPYTER_URL

# While the session file remains undeleted, keep Jupyter session running.
while [ -f $SESSION_FILE ] ; do
    sleep 10
done
