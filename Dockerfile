ARG NGINX_VERSION="1.21.6"

FROM nginx:${NGINX_VERSION} as build

ARG MODSEC_VERSION=3.0.6
ARG YAJL_VERSION=2.1.0
ARG FUZZY_VERSION=2.1.0
ARG LMDB_VERSION=0.9.29
ARG SSDEEP_VERSION=2.14.1

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        automake \
        cmake \
        doxygen \
        g++ \
        git \
        libcurl4-gnutls-dev \
        libgeoip-dev \
        liblua5.3-dev \
        libpcre++-dev \
        libtool \
        libxml2-dev \
        make \
        ruby \
        pkg-config \
        zlib1g-dev; \
     apt-get clean; \
     rm -rf /var/lib/apt/lists/*

WORKDIR /sources

RUN set -eux; \
    git clone https://github.com/LMDB/lmdb --branch LMDB_${LMDB_VERSION} --depth 1; \
    make -C lmdb/libraries/liblmdb install; \
    strip /usr/local/lib/liblmdb*.so*

RUN set -eux; \
    git clone https://github.com/lloyd/yajl --branch ${YAJL_VERSION} --depth 1; \
    cd yajl; \
    ./configure; \
    make install; \
    strip /usr/local/lib/libyajl*.so*
RUN set -eux; \
    curl -sSL https://github.com/ssdeep-project/ssdeep/releases/download/release-${SSDEEP_VERSION}/ssdeep-${SSDEEP_VERSION}.tar.gz -o ssdeep-${SSDEEP_VERSION}.tar.gz; \
    tar -xvzf ssdeep-${SSDEEP_VERSION}.tar.gz; \
    cd ssdeep-${SSDEEP_VERSION}; \
    ./configure; \
    make install; \
    strip /usr/local/lib/libfuzzy*.so*

RUN set -eux; \
    git clone https://github.com/SpiderLabs/ModSecurity --branch v${MODSEC_VERSION} --depth 1; \
    cd ModSecurity; \
    ./build.sh; \
    git submodule init; \
    git submodule update; \
    ./configure --with-yajl=/sources/yajl/build/yajl-${YAJL_VERSION}/ --with-geoip; \
    make install; \
    strip /usr/local/modsecurity/lib/lib*.so*

# We use master
RUN set -eux; \
    git clone -b master --depth 1 https://github.com/SpiderLabs/ModSecurity-nginx.git; \
    curl -sSL https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz -o nginx-${NGINX_VERSION}.tar.gz; \
    tar -xzf nginx-${NGINX_VERSION}.tar.gz; \
    cd ./nginx-${NGINX_VERSION}; \
    ./configure --with-compat --add-dynamic-module=../ModSecurity-nginx; \
    make modules; \
    strip objs/ngx_http_modsecurity_module.so; \
    cp objs/ngx_http_modsecurity_module.so /etc/nginx/modules/; \
    mkdir /etc/modsecurity.d; \
    curl -sSL https://raw.githubusercontent.com/SpiderLabs/ModSecurity/v3/master/modsecurity.conf-recommended \
         -o /etc/modsecurity.d/modsecurity.conf; \
    curl -sSL https://raw.githubusercontent.com/SpiderLabs/ModSecurity/v3/master/unicode.mapping \
         -o /etc/modsecurity.d/unicode.mapping


# =========== 
# =========== 
# =========== 
# =========== 
# =========== 
# =========== 

# setup build arguments for version of dependencies to use
ARG DOCKER_GEN_VERSION=0.9.0
ARG FOREGO_VERSION=v0.17.0

# Use a specific version of golang to build both binaries
FROM golang:1.19.1 as gobuilder

# Build docker-gen from scratch
FROM gobuilder as dockergen

ARG DOCKER_GEN_VERSION

RUN git clone https://github.com/nginx-proxy/docker-gen \
   && cd /go/docker-gen \
   && git -c advice.detachedHead=false checkout $DOCKER_GEN_VERSION \
   && go mod download \
   && CGO_ENABLED=0 GOOS=linux go build -ldflags "-X main.buildVersion=${DOCKER_GEN_VERSION}" ./cmd/docker-gen \
   && go clean -cache \
   && mv docker-gen /usr/local/bin/ \
   && cd - \
   && rm -rf /go/docker-gen

# Build forego from scratch
FROM gobuilder as forego

ARG FOREGO_VERSION

RUN git clone https://github.com/nginx-proxy/forego/ \
   && cd /go/forego \
   && git -c advice.detachedHead=false checkout $FOREGO_VERSION \
   && go mod download \
   && CGO_ENABLED=0 GOOS=linux go build -o forego . \
   && go clean -cache \
   && mv forego /usr/local/bin/ \
   && cd - \
   && rm -rf /go/forego

# Build the final image
FROM nginx:1.21.6

ARG MODSEC_VERSION=3.0.6
ARG YAJL_VERSION=2.1.0
ARG FUZZY_VERSION=2.1.0
ARG LMDB_VERSION=0.9.29
ARG SSDEEP_VERSION=2.14.1

ARG NGINX_PROXY_VERSION
# Add DOCKER_GEN_VERSION environment variable
# Because some external projects rely on it
ARG DOCKER_GEN_VERSION
ENV NGINX_PROXY_VERSION=${NGINX_PROXY_VERSION} \
   DOCKER_GEN_VERSION=${DOCKER_GEN_VERSION} \
   DOCKER_HOST=unix:///tmp/docker.sock\
   ACCESSLOG=/var/log/nginx/access.log \
   ERRORLOG=/var/log/nginx/error.log \
   LOGLEVEL=warn \
   MODSEC_AUDIT_ENGINE="RelevantOnly" \
   MODSEC_AUDIT_LOG_FORMAT=JSON \
   MODSEC_AUDIT_LOG_TYPE=Serial \
   MODSEC_AUDIT_LOG=/dev/stdout \
   MODSEC_AUDIT_LOG_PARTS='ABIJDEFHZ' \
   MODSEC_AUDIT_STORAGE=/var/log/modsecurity/audit/ \
   MODSEC_DATA_DIR=/tmp/modsecurity/data \
   MODSEC_DEBUG_LOG=/dev/null \
   MODSEC_DEBUG_LOGLEVEL=0 \
   MODSEC_PCRE_MATCH_LIMIT_RECURSION=100000 \
   MODSEC_PCRE_MATCH_LIMIT=100000 \
   MODSEC_REQ_BODY_ACCESS=on \
   MODSEC_REQ_BODY_LIMIT=13107200 \
   MODSEC_REQ_BODY_LIMIT_ACTION="Reject" \
   MODSEC_REQ_BODY_JSON_DEPTH_LIMIT=512 \
   MODSEC_REQ_BODY_NOFILES_LIMIT=131072 \
   MODSEC_RESP_BODY_ACCESS=on \
   MODSEC_RESP_BODY_LIMIT=1048576 \
   MODSEC_RESP_BODY_LIMIT_ACTION="ProcessPartial" \
   MODSEC_RESP_BODY_MIMETYPE="text/plain text/html text/xml" \
   MODSEC_RULE_ENGINE=on \
   MODSEC_STATUS_ENGINE="Off" \
   MODSEC_TAG=modsecurity \
   MODSEC_TMP_DIR=/tmp/modsecurity/tmp \
   MODSEC_TMP_SAVE_UPLOADED_FILES="on" \
   MODSEC_UPLOAD_DIR=/tmp/modsecurity/upload \
   WORKER_CONNECTIONS=1024 \
   LD_LIBRARY_PATH=/lib:/usr/lib:/usr/local/lib

RUN set -eux; \
    apt-get clean; \
    apt-get update;

RUN apt-get install dialog apt-utils -y

# Install wget and install/updates certificates
RUN apt-get update \
   && apt-get install -y -q --no-install-recommends \
   ca-certificates \
   liblua5.3-0 \
   libcurl4-gnutls-dev \
   libxml2 \
   moreutils \
   wget \
   ed \
   procps \
   certbot \
   python3-certbot-nginx \
   && apt-get clean \
   && rm -r /var/lib/apt/lists/*\
   mkdir /etc/nginx/ssl; \
   mkdir -p /tmp/modsecurity/data; \
   mkdir -p /tmp/modsecurity/upload; \
   mkdir -p /tmp/modsecurity/tmp; \
   mkdir -p /usr/local/modsecurity; \
   chown -R nginx:nginx /tmp/modsecurity

RUN wget https://github.com/SpiderLabs/owasp-modsecurity-crs/archive/v3.0.2.tar.gz; \
    tar -xzvf v3.0.2.tar.gz; \
    mv owasp-modsecurity-crs-3.0.2 /usr/local; \
    cp /usr/local/owasp-modsecurity-crs-3.0.2/crs-setup.conf.example /usr/local/owasp-modsecurity-crs-3.0.2/crs-setup.conf; \
    cp /usr/local/owasp-modsecurity-crs-3.0.2/rules/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf.example /usr/local/owasp-modsecurity-crs-3.0.2/rules/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf; \
    cp /usr/local/owasp-modsecurity-crs-3.0.2/rules/RESPONSE-999-EXCLUSION-RULES-AFTER-CRS.conf.example /usr/local/owasp-modsecurity-crs-3.0.2/rules/RESPONSE-999-EXCLUSION-RULES-AFTER-CRS.conf

COPY --from=build /usr/local/modsecurity/lib/libmodsecurity.so.${MODSEC_VERSION} /usr/local/modsecurity/lib/
COPY --from=build /usr/local/lib/libfuzzy.so.${FUZZY_VERSION} /usr/local/lib/
COPY --from=build /usr/local/lib/libyajl.so.${YAJL_VERSION} /usr/local/lib/
COPY --from=build /usr/local/lib/liblmdb.so /usr/local/lib/
COPY --from=build /etc/nginx/modules/ngx_http_modsecurity_module.so /etc/nginx/modules/ngx_http_modsecurity_module.so
COPY --from=build /etc/modsecurity.d/unicode.mapping /etc/modsecurity.d/unicode.mapping
COPY --from=build /etc/modsecurity.d/unicode.mapping /etc/nginx/modsec/unicode.mapping
COPY --from=build /etc/modsecurity.d/modsecurity.conf /etc/modsecurity.d/modsecurity.conf
COPY modsec/modsecurity.conf /etc/nginx/modsec/modsecurity.conf
COPY modsec/main.conf /etc/nginx/modsec/main.conf

RUN set -eux; \
    ln -s /usr/local/modsecurity/lib/libmodsecurity.so.${MODSEC_VERSION} /usr/local/modsecurity/lib/libmodsecurity.so.3.0; \
    ln -s /usr/local/modsecurity/lib/libmodsecurity.so.${MODSEC_VERSION} /usr/local/modsecurity/lib/libmodsecurity.so.3; \
    ln -s /usr/local/modsecurity/lib/libmodsecurity.so.${MODSEC_VERSION} /usr/local/modsecurity/lib/libmodsecurity.so; \
    ln -s /usr/local/lib/libfuzzy.so.${FUZZY_VERSION} /usr/local/lib/libfuzzy.so; \
    ln -s /usr/local/lib/libfuzzy.so.${FUZZY_VERSION} /usr/local/lib/libfuzzy.so.2; \
    ln -s /usr/local/lib/libyajl.so.${YAJL_VERSION} /usr/local/lib/libyajl.so; \
    ln -s /usr/local/lib/libyajl.so.${YAJL_VERSION} /usr/local/lib/libyajl.so.2; \
    chgrp -R 0 /var/cache/nginx/ /var/log/ /var/run/ /usr/share/nginx/ /etc/nginx/ /etc/modsecurity.d/; \
    chmod -R g=u /var/cache/nginx/ /var/log/ /var/run/ /usr/share/nginx/ /etc/nginx/ /etc/modsecurity.d/


# Configure Nginx
RUN echo "daemon off;" >> /etc/nginx/nginx.conf \
   && sed -i 's/worker_processes  1/worker_processes  auto/' /etc/nginx/nginx.conf \
   && sed -i 's/worker_connections  1024/worker_connections  10240/' /etc/nginx/nginx.conf \
   && mkdir -p '/etc/nginx/dhparam'

# Put load module on top of nginx.conf configuration
RUN stuff="load_module /etc/nginx/modules/ngx_http_modsecurity_module.so;"; \
   printf '%s\n' 1 i "$stuff" . wq | ed -s /etc/nginx/nginx.conf > /dev/null

# Change server tokens off
RUN sed -i 's/http {/http {\n\tserver_tokens off;/' /etc/nginx/nginx.conf

# Install Forego + docker-gen
COPY --from=forego /usr/local/bin/forego /usr/local/bin/forego
COPY --from=dockergen /usr/local/bin/docker-gen /usr/local/bin/docker-gen

COPY network_internal.conf /etc/nginx/

COPY app nginx.tmpl LICENSE /app/
WORKDIR /app/

ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["forego", "start", "-r"]
