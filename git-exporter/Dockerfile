ARG BUILD_FROM
FROM $BUILD_FROM AS BUILD

RUN apk add --no-cache \
		git \
		make

# hadolint ignore=DL3003
# git-secrets 1.3.0 — pinned to commit SHA to prevent tag tampering
ENV GIT_SECRET_SHA ad82d68ee924906a0401dfd48de5057731a9bc84
RUN git config --global advice.detachedHead false && \
    git init /git-secrets && \
    cd /git-secrets && \
    git remote add origin https://github.com/awslabs/git-secrets.git && \
    git fetch --depth=1 origin ${GIT_SECRET_SHA} && \
    git checkout FETCH_HEAD && \
    make install

FROM $BUILD_FROM AS RUNNING

RUN apk add --no-cache \
			git \
			rsync \
			grep \
			sed \
			python3 \
			py3-pip \
			findutils \
			jq \
	&& pip3 install --no-cache-dir --break-system-packages PyYAML==6.0.2 dotty-dict==1.3.1

COPY --from=BUILD /usr/local/bin/git-secrets /usr/local/bin/git-secrets

COPY root /
RUN chmod a+x /run.sh /utils/*
ENTRYPOINT [ "/run.sh" ]
