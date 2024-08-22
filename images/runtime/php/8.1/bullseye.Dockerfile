ARG BASE_IMAGE

# Startup script generator
FROM mcr.microsoft.com/oss/go/microsoft/golang:1.20-bullseye as startupCmdGen

# GOPATH is set to "/go" in the base image
WORKDIR /go/src
COPY src/startupscriptgenerator/src .
ARG GIT_COMMIT=unspecified
ARG BUILD_NUMBER=unspecified
ARG RELEASE_TAG_NAME=unspecified
ENV RELEASE_TAG_NAME=${RELEASE_TAG_NAME}
ENV GIT_COMMIT=${GIT_COMMIT}
ENV BUILD_NUMBER=${BUILD_NUMBER}
RUN chmod +x build.sh && ./build.sh php /opt/startupcmdgen/startupcmdgen

#FROM oryxdevmcr.azurecr.io/private/oryx/php-run-base-bullseye:{BUILD_NUMBER}
FROM ${BASE_IMAGE}
ARG IMAGES_DIR=/tmp/oryx/images

# Install the Microsoft SQL Server PDO driver on supported versions only.
#  - https://docs.microsoft.com/en-us/sql/connect/php/installation-tutorial-linux-mac
#  - https://docs.microsoft.com/en-us/sql/connect/odbc/linux-mac/installing-the-microsoft-odbc-driver-for-sql-server
RUN set -eux \
	&& apt-get update \
	&& apt-get install -y --no-install-recommends \
		gnupg2 \
		apt-transport-https \
	&& curl https://packages.microsoft.com/keys/microsoft.asc | apt-key add - \
	&& curl https://packages.microsoft.com/config/debian/11/prod.list > /etc/apt/sources.list.d/mssql-release.list \
	&& apt-get update \
	&& ACCEPT_EULA=Y apt-get install -y msodbcsql17 msodbcsql18=18.1.2.1-1 odbcinst1debian2=2.3.7 odbcinst=2.3.7 unixodbc=2.3.7 unixodbc-dev=2.3.7

ENV PHP_INI_DIR /usr/local/etc/php
RUN set -eux; \
	mkdir -p "$PHP_INI_DIR/conf.d"; \
# allow running as an arbitrary user (https://github.com/docker-library/php/issues/743)
	[ ! -d /var/www/html ]; \
	mkdir -p /var/www/html; \
	chown www-data:www-data /var/www/html; \
	chmod 777 /var/www/html
##<autogenerated>##
ENV APACHE_CONFDIR /etc/apache2
ENV APACHE_ENVVARS $APACHE_CONFDIR/envvars

RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends apache2; \
	rm -rf /var/lib/apt/lists/*; \
	\
# generically convert lines like
#   export APACHE_RUN_USER=www-data
# into
#   : ${APACHE_RUN_USER:=www-data}
#   export APACHE_RUN_USER
# so that they can be overridden at runtime ("-e APACHE_RUN_USER=...")
	sed -ri 's/^export ([^=]+)=(.*)$/: ${\1:=\2}\nexport \1/' "$APACHE_ENVVARS"; \
	\
# setup directories and permissions
	. "$APACHE_ENVVARS"; \
	for dir in \
		"$APACHE_LOCK_DIR" \
		"$APACHE_RUN_DIR" \
		"$APACHE_LOG_DIR" \
	; do \
		rm -rvf "$dir"; \
		mkdir -p "$dir"; \
		chown "$APACHE_RUN_USER:$APACHE_RUN_GROUP" "$dir"; \
# allow running as an arbitrary user (https://github.com/docker-library/php/issues/743)
		chmod 777 "$dir"; \
	done; \
	\
# delete the "index.html" that installing Apache drops in here
	rm -rvf /var/www/html/*; \
	\
# logs should go to stdout / stderr
	ln -sfT /dev/stderr "$APACHE_LOG_DIR/error.log"; \
	ln -sfT /dev/stdout "$APACHE_LOG_DIR/access.log"; \
	ln -sfT /dev/stdout "$APACHE_LOG_DIR/other_vhosts_access.log"; \
	chown -R --no-dereference "$APACHE_RUN_USER:$APACHE_RUN_GROUP" "$APACHE_LOG_DIR"

# Apache + PHP requires preforking Apache for best results
RUN a2dismod mpm_event && a2enmod mpm_prefork

# PHP files should be handled by PHP, and should be preferred over any other file type
RUN { \
		echo '<FilesMatch \.php$>'; \
		echo '\tSetHandler application/x-httpd-php'; \
		echo '</FilesMatch>'; \
		echo; \
		echo 'DirectoryIndex disabled'; \
		echo 'DirectoryIndex index.php index.html'; \
		echo; \
		echo '<Directory /var/www/>'; \
		echo '\tOptions -Indexes'; \
		echo '\tAllowOverride All'; \
		echo '</Directory>'; \
	} | tee "$APACHE_CONFDIR/conf-available/docker-php.conf" \
	&& a2enconf docker-php

ENV PHP_EXTRA_BUILD_DEPS apache2-dev
ENV PHP_EXTRA_CONFIGURE_ARGS --with-apxs2 --disable-cgi ac_cv_func_mmap=no
##</autogenerated>##

# Apply stack smash protection to functions using local buffers and alloca()
# Make PHP's main executable position-independent (improves ASLR security mechanism, and has no performance impact on x86_64)
# Enable optimization (-O2)
# Enable linker optimization (this sorts the hash buckets to improve cache locality, and is non-default)
# Adds GNU HASH segments to generated executables (this is used if present, and is much faster than sysv hash; in this configuration, sysv hash is also generated)
# https://github.com/docker-library/php/issues/272
# -D_LARGEFILE_SOURCE and -D_FILE_OFFSET_BITS=64 (https://www.php.net/manual/en/intro.filesystem.php)
ENV PHP_CFLAGS="-fstack-protector-strong -fpic -fpie -O2 -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64"
ENV PHP_CPPFLAGS="$PHP_CFLAGS"
ENV PHP_LDFLAGS="-Wl,-O1 -Wl,--hash-style=both -pie"

ENV GPG_KEYS 528995BFEDFBA7191D46839EF9BA0ADA31CBD89E 39B641343D8C104B2B146DC3F9C39DC0B9698544 F1F692238FBC1666E5A5CCD4199F9DFEF6FFBAFD

ARG PHP_VERSION
ARG PHP_SHA256

ENV PHP_VERSION ${PHP_VERSION}
ENV PHP_URL="https://www.php.net/get/php-${PHP_VERSION}.tar.xz/from/this/mirror" PHP_ASC_URL="https://www.php.net/get/php-${PHP_VERSION}.tar.xz.asc/from/this/mirror" PHP_MD5=""
ENV PHP_SHA256 ${PHP_SHA256} 

RUN set -eux; \
	\
	savedAptMark="$(apt-mark showmanual)"; \
	apt-get update; \
	apt-get install -y --no-install-recommends gnupg dirmngr; \
	rm -rf /var/lib/apt/lists/*; \
	\
	mkdir -p /usr/src; \
	cd /usr/src; \
	\
	curl -fsSL -o php.tar.xz "$PHP_URL"; \
	\
	if [ -n "$PHP_SHA256" ]; then \
		echo "$PHP_SHA256 *php.tar.xz" | sha256sum -c -; \
	fi; \
	if [ -n "$PHP_MD5" ]; then \
		echo "$PHP_MD5 *php.tar.xz" | md5sum -c -; \
	fi; \
	\
	if [ -n "$PHP_ASC_URL" ]; then \
		curl -fsSL -o php.tar.xz.asc "$PHP_ASC_URL"; \
		export GNUPGHOME="$(mktemp -d)"; \
		${IMAGES_DIR}/receiveGpgKeys.sh $GPG_KEYS; \
		gpg --batch --verify php.tar.xz.asc php.tar.xz; \
		gpgconf --kill all; \
		rm -rf "$GNUPGHOME"; \
	fi; \
	\
	apt-mark auto '.*' > /dev/null; \
	apt-mark manual $savedAptMark > /dev/null; \
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false

COPY images/runtime/php/8.1/docker-php-source /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-php-source

RUN set -eux; \
	savedAptMark="$(apt-mark showmanual)"; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		libargon2-dev \
		libcurl4-openssl-dev \
		libedit-dev \
		libonig-dev \
		libsodium-dev \
		libsqlite3-dev \
		libssl-dev \
		libxml2-dev \
		zlib1g-dev \
		${PHP_EXTRA_BUILD_DEPS:-} \
	; \
	rm -rf /var/lib/apt/lists/*; \
	\
	export \
		CFLAGS="$PHP_CFLAGS" \
		CPPFLAGS="$PHP_CPPFLAGS" \
		LDFLAGS="$PHP_LDFLAGS" \
	; \
	docker-php-source extract; \
	cd /usr/src/php; \
	gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"; \
	debMultiarch="$(dpkg-architecture --query DEB_BUILD_MULTIARCH)"; \
# https://bugs.php.net/bug.php?id=74125
	if [ ! -d /usr/include/curl ]; then \
		ln -sT "/usr/include/$debMultiarch/curl" /usr/local/include/curl; \
	fi; \
	./configure \
		--build="$gnuArch" \
		--with-config-file-path="$PHP_INI_DIR" \
		--with-config-file-scan-dir="$PHP_INI_DIR/conf.d" \
		\
# make sure invalid --configure-flags are fatal errors intead of just warnings
		--enable-option-checking=fatal \
		\
# https://github.com/docker-library/php/issues/439
		--with-mhash \
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
# in PHP 7.4+, the pecl/pear installers are officially deprecated (requiring an explicit "--with-pear") and will be removed in PHP 8+; see also https://github.com/docker-library/php/issues/846#issuecomment-505638494
		--with-pear \
		\
# bundled pcre does not support JIT on s390x
# https://manpages.debian.org/stretch/libpcre3-dev/pcrejit.3.en.html#AVAILABILITY_OF_JIT_SUPPORT
		$(test "$gnuArch" = 's390x-linux-gnu' && echo '--without-pcre-jit') \
		--with-libdir="lib/$debMultiarch" \
		\
		${PHP_EXTRA_CONFIGURE_ARGS:-} \
	; \
	make -j "$(nproc)"; \
	find -type f -name '*.a' -delete; \
	make install; \
	find /usr/local/bin /usr/local/sbin -type f -executable -exec strip --strip-all '{}' + || true; \
	make clean; \
	\
# https://github.com/docker-library/php/issues/692 (copy default example "php.ini" files somewhere easily discoverable)
	cp -v php.ini-* "$PHP_INI_DIR/"; \
	\
	cd /; \
	docker-php-source delete; \
	\
# reset apt-mark's "manual" list so that "purge --auto-remove" will remove all build dependencies
	apt-mark auto '.*' > /dev/null; \
	[ -z "$savedAptMark" ] || apt-mark manual $savedAptMark; \
	find /usr/local -type f -executable -exec ldd '{}' ';' \
		| awk '/=>/ { print $(NF-1) }' \
		| sort -u \
		| xargs -r dpkg-query --search \
		| cut -d: -f1 \
		| sort -u \
		| xargs -r apt-mark manual \
	; \
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
	\
# update pecl channel definitions https://github.com/docker-library/php/issues/443
	pecl update-channels; \
	rm -rf /tmp/pear ~/.pearrc; \
# smoke test
	php --version

COPY images/runtime/php/8.1/docker-php-ext-* images/runtime/php/8.1/docker-php-entrypoint /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-php-*

# sodium was built as a shared module (so that it can be replaced later if so desired), so let's enable it too (https://github.com/docker-library/php/issues/598)
RUN docker-php-ext-enable sodium \
	&& rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["docker-php-entrypoint"]
##<autogenerated>##
# https://httpd.apache.org/docs/2.4/stopping.html#gracefulstop
STOPSIGNAL SIGWINCH

COPY images/runtime/php/8.1/apache2-foreground /usr/local/bin/
RUN chmod +x /usr/local/bin/apache2-foreground
WORKDIR /var/www/html

EXPOSE 80
CMD ["apache2-foreground"]
##</autogenerated>##

## base dockerfile
SHELL ["/bin/bash", "-c"]
ARG PHP_VERSION
ENV PHP_VERSION ${PHP_VERSION} 

RUN a2enmod rewrite expires include deflate remoteip headers

ENV APACHE_RUN_USER www-data
# Edit the default DocumentRoot setting
ENV APACHE_DOCUMENT_ROOT /home/site/wwwroot
RUN sed -ri -e 's!/var/www/html!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/sites-available/*.conf
RUN sed -ri -e 's!/var/www/!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf
# Edit the default port setting
ENV APACHE_PORT 8080
RUN sed -ri -e 's!<VirtualHost \*:80>!<VirtualHost *:${APACHE_PORT}>!g' /etc/apache2/sites-available/*.conf
RUN sed -ri -e 's!<VirtualHost _default_:443>!<VirtualHost _default_:${APACHE_PORT}>!g' /etc/apache2/sites-available/*.conf
RUN sed -ri -e 's!Listen 80!Listen ${APACHE_PORT}!g' /etc/apache2/ports.conf
# Edit Configuration to instruct Apache on how to process PHP files
RUN echo -e '<FilesMatch "\.(?i:ph([[p]?[0-9]*|tm[l]?))$">\n SetHandler application/x-httpd-php\n</FilesMatch>' >> /etc/apache2/apache2.conf
# Disable Apache2 server signature
RUN echo -e 'ServerSignature Off' >> /etc/apache2/apache2.conf
RUN echo -e 'ServerTokens Prod' >> /etc/apache2/apache2.conf
RUN { \
   echo '<DirectoryMatch "^/.*/\.git/">'; \
   echo '   Order deny,allow'; \
   echo '   Deny from all'; \
   echo '</DirectoryMatch>'; \
} >> /etc/apache2/apache2.conf

# Install common PHP extensions
# TEMPORARY: Holding odbc related packages from upgrading.
RUN apt-mark hold msodbcsql18 odbcinst1debian2 odbcinst unixodbc unixodbc-dev \
    && apt-get update \
    && apt-get upgrade -y \
    && ln -s /usr/lib/x86_64-linux-gnu/libldap.so /usr/lib/libldap.so \
    && ln -s /usr/lib/x86_64-linux-gnu/liblber.so /usr/lib/liblber.so \
    && ln -s /usr/include/x86_64-linux-gnu/gmp.h /usr/include/gmp.h

RUN set -eux; \
    if [[ $PHP_VERSION == 7.4.* || $PHP_VERSION == 8.0.* || $PHP_VERSION == 8.1.* || $PHP_VERSION == 8.2.* || $PHP_VERSION == 8.3.* ]]; then \
		apt-get update \
        && apt-get upgrade -y \
        && apt-get install -y --no-install-recommends apache2-dev \
        && docker-php-ext-configure gd --with-freetype --with-jpeg \
        && PHP_OPENSSL=yes docker-php-ext-configure imap --with-kerberos --with-imap-ssl ; \
    else \
		docker-php-ext-configure gd --with-png-dir=/usr --with-jpeg-dir=/usr \
        && docker-php-ext-configure imap --with-kerberos --with-imap-ssl ; \
    fi

RUN docker-php-ext-configure pdo_odbc --with-pdo-odbc=unixODBC,/usr \
    && docker-php-ext-install gd \
        mysqli \
        opcache \
        pdo \
        pdo_mysql \
        pdo_pgsql \
        pgsql \
        ldap \
        intl \
        gmp \
        zip \
        bcmath \
        mbstring \
        pcntl \
        calendar \
        exif \
        gettext \
        imap \
        tidy \
        shmop \
        soap \
        sockets \
        sysvmsg \
        sysvsem \
        sysvshm \
        pdo_odbc \
# deprecated from 7.4, so should be avoided in general template for all php versions
#       wddx \
#       xmlrpc \
        xsl

RUN set -eux; \
    if [[ $PHP_VERSION != 5.* ]]; then \
        pecl install redis && docker-php-ext-enable redis; \
    fi

# https://github.com/Imagick/imagick/issues/331
# https://github.com/ihneo/php/pull/24/files
RUN set -eux; \	
    if [[ $PHP_VERSION != 8.3.* ]]; then \
        pecl install imagick && docker-php-ext-enable imagick; \
    fi

# deprecated from 5.*, so should be avoided 
RUN set -eux; \
    if [[ $PHP_VERSION != 5.* && $PHP_VERSION != 7.0.* ]]; then \
        echo "pecl/mongodb requires PHP (version >= 7.1.0, version <= 7.99.99)"; \
        pecl install mongodb && docker-php-ext-enable mongodb; \
    fi

# https://github.com/microsoft/mysqlnd_azure, Supports  7.2*, 7.3* and 7.4*
RUN set -eux; \
    if [[ $PHP_VERSION == 7.2.* || $PHP_VERSION == 7.3.* || $PHP_VERSION == 7.4.* ]]; then \
        echo "pecl/mysqlnd_azure requires PHP (version >= 7.2.*, version <= 7.99.99)"; \
        pecl install mysqlnd_azure \
        && docker-php-ext-enable mysqlnd_azure; \
    fi

# Install the Microsoft SQL Server PDO driver on supported versions only.
#  - https://docs.microsoft.com/en-us/sql/connect/php/installation-tutorial-linux-mac
#  - https://docs.microsoft.com/en-us/sql/connect/odbc/linux-mac/installing-the-microsoft-odbc-driver-for-sql-server
# For php|8.0, latest stable version of pecl/sqlsrv, pecl/pdo_sqlsrv is 5.11.0
RUN set -eux; \
    if [[ $PHP_VERSION == 8.0.* ]]; then \
        pecl install sqlsrv-5.11.0 pdo_sqlsrv-5.11.0 \
        && echo extension=pdo_sqlsrv.so >> $(php --ini | grep "Scan for additional .ini files" | sed -e "s|.*:\s*||")/30-pdo_sqlsrv.ini \
        && echo extension=sqlsrv.so >> $(php --ini | grep "Scan for additional .ini files" | sed -e "s|.*:\s*||")/20-sqlsrv.ini; \
    fi

# Latest pecl/sqlsrv, pecl/pdo_sqlsrv requires PHP (version >= 8.1.0)
RUN set -eux; \
    if [[ $PHP_VERSION == 8.1.* || $PHP_VERSION == 8.2.* ||  $PHP_VERSION == 8.3.* ]]; then \
        pecl install sqlsrv pdo_sqlsrv \
        && echo extension=pdo_sqlsrv.so >> `php --ini | grep "Scan for additional .ini files" | sed -e "s|.*:\s*||"`/30-pdo_sqlsrv.ini \
        && echo extension=sqlsrv.so >> `php --ini | grep "Scan for additional .ini files" | sed -e "s|.*:\s*||"`/20-sqlsrv.ini; \
    fi

RUN { \
                echo 'opcache.memory_consumption=128'; \
                echo 'opcache.interned_strings_buffer=8'; \
                echo 'opcache.max_accelerated_files=4000'; \
                echo 'opcache.revalidate_freq=60'; \
                echo 'opcache.fast_shutdown=1'; \
                echo 'opcache.enable_cli=1'; \
    } > /usr/local/etc/php/conf.d/opcache-recommended.ini

# NOTE: zend_extension=opcache is already configured via docker-php-ext-install, above
RUN { \
                echo 'error_log=/var/log/apache2/php-error.log'; \
                echo 'display_errors=Off'; \
                echo 'log_errors=On'; \
                echo 'display_startup_errors=Off'; \
                echo 'date.timezone=UTC'; \
    } > /usr/local/etc/php/conf.d/php.ini

RUN set -x \
    && docker-php-source extract \
    && cd /usr/src/php/ext/odbc \
    && phpize \
    && sed -ri 's@^ *test +"\$PHP_.*" *= *"no" *&& *PHP_.*=yes *$@#&@g' configure \
    && chmod +x ./configure \
    && ./configure --with-unixODBC=shared,/usr \
    && docker-php-ext-install odbc \
    && rm -rf /var/lib/apt/lists/*

RUN rm -rf /tmp/oryx

ENV LANG="C.UTF-8" \
    LANGUAGE="C.UTF-8" \
    LC_ALL="C.UTF-8"

## dockerfile

# Bake Application Insights key from pipeline variable into final image
ARG AI_CONNECTION_STRING
ENV ORYX_AI_CONNECTION_STRING=${AI_CONNECTION_STRING}
#Bake in client certificate path into image to avoid downloading it
ENV PATH_CA_CERTIFICATE="/etc/ssl/certs/ca-certificate.crt"

# Oryx++ Builder variables
ENV CNB_STACK_ID="oryx.stacks.skeleton"
LABEL io.buildpacks.stack.id="oryx.stacks.skeleton"

COPY --from=startupCmdGen /opt/startupcmdgen/startupcmdgen /opt/startupcmdgen/startupcmdgen
RUN ln -s /opt/startupcmdgen/startupcmdgen /usr/local/bin/oryx \
	&& rm -rf /tmp/oryx \
	# Temporarily making sure apache2-foreground has permission
	&& chmod +x /usr/local/bin/apache2-foreground

ENV LANG="C.UTF-8" \
	LANGUAGE="C.UTF-8" \
	LC_ALL="C.UTF-8"