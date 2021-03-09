FROM php:7-alpine3.12 AS php

FROM httpd:2-alpine

COPY --from=php /usr/local/bin/docker-php-source /usr/local/bin/
COPY --from=php /usr/local/bin/docker-php-ext-* /usr/local/bin/
COPY httpd.conf /usr/local/apache2/conf/httpd.conf

ENV PHPIZE_DEPS \
    autoconf \
    dpkg-dev dpkg \
    file \
    g++ \
    gcc \
    libc-dev \
    make \
    pkgconf \
    re2c

RUN apk add --no-cache \
    ca-certificates \
    curl \
    tar \
    xz \
    # https://github.com/docker-library/php/issues/494
    openssl

ENV PHP_INI_DIR /usr/local/etc/php
RUN set -eux; \
    mkdir -p "$PHP_INI_DIR/conf.d"; \
    # allow running as an arbitrary user (https://github.com/docker-library/php/issues/743)
    [ ! -d /var/www/html ]; \
    mkdir -p /var/www/html; \
    chown www-data:www-data /var/www/html; \
    chmod 777 /var/www/html

ENV PHP_CFLAGS="-fstack-protector-strong -fpic -fpie -O2 -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64"
ENV PHP_CPPFLAGS="$PHP_CFLAGS"
ENV PHP_LDFLAGS="-Wl,-O1 -pie"

ENV GPG_KEYS 42670A7FE4D0441C8E4632349E4FDC074A4EF02D 5A52880781F755608BF815FC910DEB46F53EA312

ENV PHP_VERSION 7.4.15
ENV PHP_URL="https://www.php.net/distributions/php-7.4.15.tar.xz" PHP_ASC_URL="https://www.php.net/distributions/php-7.4.15.tar.xz.asc"
ENV PHP_SHA256="9b859c65f0cf7b3eff9d4a28cfab719fb3d36a1db3c20d874a79b5ec44d43cb8"

RUN set -eux; \
    \
    apk add --no-cache --virtual .fetch-deps gnupg; \
    \
    mkdir -p /usr/src; \
    cd /usr/src; \
    \
    curl -fsSL -o php.tar.xz "$PHP_URL"; \
    \
    if [ -n "$PHP_SHA256" ]; then \
    echo "$PHP_SHA256 *php.tar.xz" | sha256sum -c -; \
    fi; \
    \
    if [ -n "$PHP_ASC_URL" ]; then \
    curl -fsSL -o php.tar.xz.asc "$PHP_ASC_URL"; \
    export GNUPGHOME="$(mktemp -d)"; \
    for key in $GPG_KEYS; do \
    gpg --batch --keyserver ha.pool.sks-keyservers.net --recv-keys "$key"; \
    done; \
    gpg --batch --verify php.tar.xz.asc php.tar.xz; \
    gpgconf --kill all; \
    rm -rf "$GNUPGHOME"; \
    fi; \
    \
    apk del --no-network .fetch-deps

RUN set -eux; \
    apk add --no-cache --virtual .build-deps \
    $PHPIZE_DEPS \
    argon2-dev \
    coreutils \
    curl-dev \
    libedit-dev \
    libsodium-dev \
    libxml2-dev \
    linux-headers \
    oniguruma-dev \
    openssl-dev \
    sqlite-dev \
    apr-util-dev \
    zlib-dev \
    libmemcached-dev \
    postgresql-dev \
    gmp \
    zlib-dev \
    libpng-dev \
    zstd-dev \
    ; \
    \
    export CFLAGS="$PHP_CFLAGS" \
    CPPFLAGS="$PHP_CPPFLAGS" \
    LDFLAGS="$PHP_LDFLAGS" \
    ; \
    docker-php-source extract; \
    cd /usr/src/php; \
    gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"; \
    ./configure \
    --build="$gnuArch" \
    --with-config-file-path="$PHP_INI_DIR" \
    --with-config-file-scan-dir="$PHP_INI_DIR/conf.d" \
    --with-apxs2=/usr/local/apache2/bin/apxs \
    \
    # make sure invalid --configure-flags are fatal errors instead of just warnings
    --enable-option-checking=fatal \
    \
    # https://github.com/docker-library/php/issues/439
    --with-mhash \
    \
    # https://github.com/docker-library/php/issues/822
    --with-pic \
    \
    # --enable-ftp is included here because ftp_ssl_connect() needs ftp to be compiled statically (see https://github.com/docker-library/php/issues/236)
    --enable-ftp \
    # --enable-mbstring is included here because otherwise there's no way to get pecl to use it properly (see https://github.com/docker-library/php/issues/195)
    --enable-mbstring \
    # --enable-mysqlnd is included here because it's harder to compile after the fact than extensions are (since it's a plugin for several extensions, not an extension in itself)
    --enable-mysqlnd \
    # https://wiki.php.net/rfc/argon2_password_hash (7.2+)
    --with-password-argon2 \
    # https://wiki.php.net/rfc/libsodium
    --with-sodium=shared \
    # always build against system sqlite3 (https://github.com/php/php-src/commit/6083a387a81dbbd66d6316a3a12a63f06d5f7109)
    --with-pdo-sqlite=/usr \
    --with-sqlite3=/usr \
    \
    --with-curl \
    --with-libedit \
    --with-openssl \
    --with-zlib \
    \
    # in PHP 7.4+, the pecl/pear installers are officially deprecated (requiring an explicit "--with-pear")
    --with-pear \
    \
    # bundled pcre does not support JIT on s390x
    # https://manpages.debian.org/stretch/libpcre3-dev/pcrejit.3.en.html#AVAILABILITY_OF_JIT_SUPPORT
    $(test "$gnuArch" = 's390x-linux-musl' && echo '--without-pcre-jit') \
    \
    ${PHP_EXTRA_CONFIGURE_ARGS:-} \
    ; \
    make -j "$(nproc)"; \
    find -type f -name '*.a' -delete; \
    make install; \
    find /usr/local/bin /usr/local/sbin -type f -perm +0111 -exec strip --strip-all '{}' + || true; \
    make clean; \
    \
    # https://github.com/docker-library/php/issues/692 (copy default example "php.ini" files somewhere easily discoverable)
    cp -v php.ini-* "$PHP_INI_DIR/"; \
    \
    cd /; \
    docker-php-source delete; \
    \
    pecl install --configureoptions 'enable-apcu-debug="no"' APCu-5.1.19; \
    pecl install igbinary-3.1.6; \
    pecl install --configureoptions 'with-libmemcached-dir="no" with-zlib-dir="no" with-system-fastlz="no" enable-memcached-igbinary="yes" enable-memcached-msgpack="no" enable-memcached-json="yes" enable-memcached-protocol="no" enable-memcached-sasl="no" enable-memcached-session="no"' memcached-3.1.5; \
    pecl install --configureoptions 'enable-redis-igbinary="yes" enable-redis-lzf="yes" enable-redis-zstd="yes"' redis-5.3.3; \
    \
    docker-php-ext-configure pgsql; \
    docker-php-ext-install pdo pdo_pgsql; \
    \
    docker-php-ext-configure bcmath; \
    docker-php-ext-install bcmath; \
    \
    docker-php-ext-configure gd; \
    docker-php-ext-install gd; \
    \
    docker-php-ext-enable \
    apcu \
    igbinary \
    memcached \
    redis \
    ; \
    \
    runDeps="$( \
    scanelf --needed --nobanner --format '%n#p' --recursive /usr/local \
    | tr ',' '\n' \
    | sort -u \
    | awk 'system("[ -e /usr/local/lib/" $1 " ]") == 0 { next } { print "so:" $1 }' \
    )"; \
    apk add --no-cache $runDeps; \
    \
    apk del --no-network .build-deps; \
    \
    # update pecl channel definitions https://github.com/docker-library/php/issues/443
    pecl update-channels; \
    rm -rf /tmp/pear ~/.pearrc; \
    \
    rm -rf /var/cache/apk/*; \
    \
    mkdir -p /var/www/html/public; \
    echo '<?php phpinfo();' > /var/www/html/public/index.php; \
    chown -R www-data:www-data /var/www; \
    \
    # smoke test
    php --version

RUN docker-php-ext-enable sodium

STOPSIGNAL SIGWINCH

WORKDIR /var/www/html/public

EXPOSE 80
CMD ["httpd-foreground"]
