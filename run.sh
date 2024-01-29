#!/bin/bash

function install_conda() {
	echo "Checking if miniconda3 is installed..."
	if [ ! -d "$WORK/miniconda3" ]; then
		echo "Miniconda not found in $WORK..."
		echo "Installing..."
		mkdir -p "$WORK/miniconda3"
		curl https://repo.anaconda.com/miniconda/Miniconda3-py311_23.10.0-1-Linux-x86_64.sh -o "$WORK/miniconda3/miniconda.sh"
		bash "$WORK/miniconda3/miniconda.sh" -b -u -p "$WORK/miniconda3"
		rm -rf "$WORK/miniconda3/miniconda.sh"
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
}

function load_cuda() {
	echo "Loading CUDA..."
	module load cuda/12.0
}

function export_repo_variables() {
	COOKBOOK_NAME="sites-and-stories-nlp"
	COOKBOOK_CONDA_ENV="llm"
	COOKBOOK_DIR=${WORK}/cookbooks
	GIT_REPO_URL="https://github.com/In-For-Disaster-Analytics/sites-and-stories-nlp.git"
	GIT_BRANCH="jupyterenv"
	COOKBOOK_WORKSPACE_DIR=${COOKBOOK_DIR}/${COOKBOOK_NAME}
	COOKBOOK_REPOSITORY_PARENT_DIR=${COOKBOOK_DIR}/.repository
	COOKBOOK_REPOSITORY_DIR=${COOKBOOK_REPOSITORY_PARENT_DIR}/${COOKBOOK_NAME}
	UPDATE_AVAILABLE_FILE=${COOKBOOK_WORKSPACE_DIR}/UPDATE_AVAILABLE.txt
	NODE_HOSTNAME_PREFIX=$(hostname -s) # Short Host Name  -->  name of compute node: c###-###
	NODE_HOSTNAME_DOMAIN=$(hostname -d) # DNS Name  -->  stampede2.tacc.utexas.edu
	NODE_HOSTNAME_LONG=$(hostname -f)   # Fully Qualified Domain Name  -->  c###-###.stampede2.tacc.utexas.edu
	export COOKBOOK_NAME
	export COOKBOOK_DIR
	export GIT_REPO_URL
	export GIT_BRANCH
	export COOKBOOK_WORKSPACE_DIR
	export COOKBOOK_REPOSITORY_DIR
	export COOKBOOK_REPOSITORY_PARENT_DIR
	export UPDATE_AVAILABLE_FILE
	export NODE_HOSTNAME_PREFIX
	export NODE_HOSTNAME_DOMAIN
	export NODE_HOSTNAME_LONG
	export COOKBOOK_CONDA_ENV
}

function remove_update_available_file() {
	if [ -f "${UPDATE_AVAILABLE_FILE}" ]; then
		rm "${UPDATE_AVAILABLE_FILE}"
	fi
}

function detect_update_available() {
	git remote update
	LAST_UPDATE=$(git show --no-notes --format=format:"%H" "${GIT_BRANCH}" | head -n 1)
	LAST_COMMIT=$(git show --no-notes --format=format:"%H" "origin/${GIT_BRANCH}" | head -n 1)
	if [ $LAST_COMMIT != $LAST_UPDATE ]; then
		echo "Update available for ${COOKBOOK_NAME} cookbook" >"${UPDATE_AVAILABLE_FILE}"
		echo "To update the conda environment. Please run" >>"${UPDATE_AVAILABLE_FILE}"
		echo "conda env update --file ${COOKBOOK_REPOSITORY_DIR}/.binder/environment.yml --prune " >>"${UPDATE_AVAILABLE_FILE}"
		echo "pip install --no-cache-dir -r ${COOKBOOK_REPOSITORY_DIR}/.binder/requirements.txt " >>"${UPDATE_AVAILABLE_FILE}"
	fi
}

function clone_cookbook_on_workspace() {
	if [ ! -d "$COOKBOOK_WORKSPACE_DIR" ]; then
		git clone ${GIT_REPO_URL} --branch ${GIT_BRANCH} ${COOKBOOK_WORKSPACE_DIR}
	else
		pushd ${COOKBOOK_WORKSPACE_DIR}
		detect_update_available
		popd
	fi
}

function clone_cookbook_on_archive() {
	if [ ! -d "${COOKBOOK_REPOSITORY_DIR}" ]; then
		mkdir -p ${COOKBOOK_REPOSITORY_DIR}
		git clone ${GIT_REPO_URL} --branch ${GIT_BRANCH} ${COOKBOOK_REPOSITORY_DIR}
	else
		git -C ${COOKBOOK_REPOSITORY_DIR} pull origin ${GIT_BRANCH}
	fi
}

function init_directory() {
	mkdir -p ${COOKBOOK_REPOSITORY_PARENT_DIR}
	remove_update_available_file
	clone_cookbook_on_workspace
	clone_cookbook_on_archive
}

function get_tap_certificate() {
	mkdir -p ${HOME}/.tap # this should exist at this point, but just in case...
	export TAP_CERTFILE=${HOME}/.tap/.${SLURM_JOB_ID}
	# bail if we cannot create a secure session
	if [ ! -f ${TAP_CERTFILE} ]; then
		echo "TACC: ERROR - could not find TLS cert for secure session"
		echo "TACC: job ${SLURM_JOB_ID} execution finished at: $(date)"
		exit 1
	fi
}

function get_tap_token() {
	# bail if we cannot create a token for the session
	TAP_TOKEN=$(tap_get_token)
	if [ -z "${TAP_TOKEN}" ]; then
		echo "TACC: ERROR - could not generate token for jupyter session"
		echo "TACC: job ${SLURM_JOB_ID} execution finished at: $(date)"
		exit 1
	fi
	echo "TACC: using token ${TAP_TOKEN}"
	LOGIN_PORT=$(tap_get_port)
	export TAP_TOKEN
	export LOGIN_PORT
}

function load_tap_functions() {
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
}

function create_jupyter_configuration {
	mkdir -p ${HOME}/.tap
	TAP_JUPYTER_CONFIG="${HOME}/.tap/jupyter_config.py"
	JUPYTER_SERVER_APP="ServerApp"
	JUPYTER_BIN="jupyter-lab"
	LOCAL_PORT=5902
	echo ${PWD}

	cat <<-EOF >${TAP_JUPYTER_CONFIG}
		# Configuration file for TAP jupyter session
		import ssl
		c = get_config()
		c.IPKernelApp.pylab = "inline"  # if you want plotting support always
		c.${JUPYTER_SERVER_APP}.ip = "0.0.0.0"
		c.${JUPYTER_SERVER_APP}.port = $LOCAL_PORT
		c.${JUPYTER_SERVER_APP}.open_browser = False
		c.${JUPYTER_SERVER_APP}.allow_origin = u"*"
		c.${JUPYTER_SERVER_APP}.ssl_options = {"ssl_version": ssl.PROTOCOL_TLSv1_2}
		c.${JUPYTER_SERVER_APP}.root_dir = "${_tapisJobWorkingDir}"
		c.${JUPYTER_SERVER_APP}.preferred_dir = "${_tapisJobWorkingDir}"
		c.${JUPYTER_SERVER_APP}.notebook_dir = "${_tapisJobWorkingDir}/work"
		c.FileContentsManager.delete_to_trash = False
		c.IdentityProvider.token = "${TAP_TOKEN}"
		c.MultiKernelManager.default_kernel_name = "${COOKBOOK_CONDA_ENV}"
	EOF

}

function run_jupyter() {
	NB_SERVERDIR=$HOME/.jupyter
	JUPYTER_SERVER_APP="ServerApp"
	JUPYTER_BIN="jupyter-lab"
	JUPYTER_ARGS="--certfile=$(cat ${TAP_CERTFILE}) --config=${TAP_JUPYTER_CONFIG}"
	JUPYTER_LOGFILE=${NB_SERVERDIR}/${NODE_HOSTNAME_PREFIX}.log
	mkdir -p ${NB_SERVERDIR}
	touch $JUPYTER_LOGFILE
	nohup ${JUPYTER_BIN} ${JUPYTER_ARGS} &>${JUPYTER_LOGFILE} &
	JUPYTER_PID=$!
	# verify jupyter is up. if not, give one more try, then bail
	if ! $(ps -fu ${USER} | grep ${JUPYTER_BIN} | grep -qv grep); then
		# sometimes jupyter has a bad day. give it another chance to be awesome.
		echo "TACC: first jupyter launch failed. Retrying..."
		nohup ${JUPYTER_BIN} ${JUPYTER_ARGS} &>${JUPYTER_LOGFILE} &
	fi

	if ! $(ps -fu ${USER} | grep ${JUPYTER_BIN} | grep -qv grep); then
		# jupyter will not be working today. sadness.
		echo "TACC: ERROR - jupyter failed to launch"
		echo "TACC: ERROR - this is often due to an issue in your python or conda environment"
		echo "TACC: ERROR - jupyter logfile contents:"
		cat ${JUPYTER_LOGFILE}
		echo "TACC: job ${SLURM_JOB_ID} execution finished at: $(date)"
		exit 1
	fi

}

function port_fowarding() {
	LOCAL_PORT=5902
	# Disable exit on error so we can check the ssh tunnel status.
	set +e
	for i in $(seq 2); do
		ssh -o StrictHostKeyChecking=no -q -f -g -N -R ${LOGIN_PORT}:${NODE_HOSTNAME_PREFIX}:${LOCAL_PORT} login${i}
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
	# Re-enable exit on error.
	set -e
}

function send_url_to_webhook() {
	JUPYTER_URL="https://${NODE_HOSTNAME_DOMAIN}:${LOGIN_PORT}/?token=${TAP_TOKEN}"
	INTERACTIVE_WEBHOOK_URL="${_webhook_base_url}"
	# Wait a few seconds for jupyter to boot up and send webhook callback url for job ready notification.
	# Notification is sent to _INTERACTIVE_WEBHOOK_URL, e.g. https://3dem.org/webhooks/interactive/
	(
		sleep 5 &&
			curl -k --data "event_type=interactive_session_ready&address=${JUPYTER_URL}&owner=${_tapisJobOwner}&job_uuid=${_tapisJobUUID}" "${_INTERACTIVE_WEBHOOK_URL}" &
	) &

}

function session_cleanup() {
	# This file will be located in the directory mounted by the job.
	SESSION_FILE=delete_me_to_end_session
	touch $SESSION_FILE
	echo $NODE_HOSTNAME_LONG $IPYTHON_PID >$SESSION_FILE
	# While the session file remains undeleted, keep Jupyter session running.
	while [ -f $SESSION_FILE ]; do
		sleep 10
	done
}

function install_dependencies() {
	### Create env
	if { conda env list | grep "${COOKBOOK_CONDA_ENV}"; } >/dev/null 2>&1; then
		conda activate ${COOKBOOK_CONDA_ENV}
	else
		conda env create -n ${COOKBOOK_CONDA_ENV} -f $COOKBOOK_WORKSPACE_DIR/.binder/environment.yml --force
		conda activate ${COOKBOOK_CONDA_ENV}
		pip install --no-cache-dir -r $COOKBOOK_WORKSPACE_DIR/.binder/requirements.txt
		python -m ipykernel install --user --name "${COOKBOOK_CONDA_ENV}" --display-name "Python (${COOKBOOK_CONDA_ENV})"
	fi
	conda install -n ${COOKBOOK_CONDA_ENV} -c conda-forge jupyterlab_widgets
	conda install -n ${COOKBOOK_CONDA_ENV} -c conda-forge ipywidgets

}

set -xe

install_conda
load_cuda
export_repo_variables
init_directory
load_tap_functions
get_tap_certificate
get_tap_token
create_jupyter_configuration
install_dependencies
run_jupyter
port_fowarding
send_url_to_webhook
session_cleanup

