FROM nvidia/cuda:12.3.0-devel-ubuntu22.04

LABEL maintainer="TACC-ACI-WMA <wma_prtl@tacc.utexas.edu>"

USER root

EXPOSE 8888

ENV DEBIAN_FRONTEND noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    fonts-liberation \
    git \
    locales \
    pandoc \
    python3 \
    python3-pip \
    ssh \
    vim \
    && apt-get clean && rm -rf /var/lib/apt/lists/* && \
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && \
    locale-gen

RUN pip install --upgrade --no-cache-dir \
    pip \
    setuptools \
    wheel

# Install jupyterlab and ML packages using host cache
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install \
    jupyterlab \
    tensorflow[and-cuda] \
    torch

# Add container user and group
ARG NB_USER=jovyan
ARG NB_UID=1000
ARG NB_GID=100

# Configure environment
ENV SHELL=/bin/bash \
    NB_USER="${NB_USER}" \
    NB_UID=${NB_UID} \
    NB_GID=${NB_GID} \
    NB_HOME="/home/${NB_USER}" \
    LC_ALL=en_US.UTF-8 \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US.UTF-8

# Enable prompt color in the skeleton .bashrc before creating the default NB_USER
RUN sed -i 's/^#force_color_prompt=yes/force_color_prompt=yes/' /etc/skel/.bashrc

# Create NB_USER with UID=NB_UID and GID=NB_GID
RUN useradd --no-log-init --create-home --shell /bin/bash --uid "${NB_UID}" --gid "${NB_GID}" "${NB_USER}"

COPY run.sh /tapis/run.sh

RUN chmod +x /tapis/run.sh

USER ${NB_UID}

# Setup work directory
RUN mkdir "${NB_HOME}/work"

WORKDIR "${NB_HOME}"

ENTRYPOINT [ "/tapis/run.sh" ]

# Leave these args here to better use the Docker build cache
ARG CONDA_VERSION=py311_23.10.0-1

RUN set -x && \
    UNAME_M="$(uname -m)" && \
    if [ "${UNAME_M}" = "x86_64" ]; then \
        MINICONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-${CONDA_VERSION}-Linux-x86_64.sh"; \
        SHA256SUM="d0643508fa49105552c94a523529f4474f91730d3e0d1f168f1700c43ae67595"; \
    elif [ "${UNAME_M}" = "s390x" ]; then \
        MINICONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-${CONDA_VERSION}-Linux-s390x.sh"; \
        SHA256SUM="ae212385c9d7f7473da7401d3f5f6cbbbc79a1fce730aa48531947e9c07e0808"; \
    elif [ "${UNAME_M}" = "aarch64" ]; then \
        MINICONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-${CONDA_VERSION}-Linux-aarch64.sh"; \
        SHA256SUM="a60e70ad7e8ac5bb44ad876b5782d7cdc66e10e1f45291b29f4f8d37cc4aa2c8"; \
    elif [ "${UNAME_M}" = "ppc64le" ]; then \
        MINICONDA_URL="https://repo.anaconda.com/miniconda/Miniconda3-${CONDA_VERSION}-Linux-ppc64le.sh"; \
        SHA256SUM="1a2eda0a9a52a4bd058abbe9de5bb2bc751fcd7904c4755deffdf938d6f4436e"; \
    fi && \
    wget "${MINICONDA_URL}" -O miniconda.sh -q && \
    echo "${SHA256SUM} miniconda.sh" > shasum && \
    if [ "${CONDA_VERSION}" != "latest" ]; then sha256sum --check --status shasum; fi && \
    mkdir -p /opt && \
    bash miniconda.sh -b -p /opt/conda && \
    rm miniconda.sh shasum && \
    ln -s /opt/conda/etc/profile.d/conda.sh /etc/profile.d/conda.sh && \
    echo ". /opt/conda/etc/profile.d/conda.sh" >> ~/.bashrc && \
    echo "conda activate base" >> ~/.bashrc && \
    find /opt/conda/ -follow -type f -name '*.a' -delete && \
    find /opt/conda/ -follow -type f -name '*.js.map' -delete && \
    /opt/conda/bin/conda clean -afy