# This dockerfile is intended to built using buildx to enable multi-platform
# images...
# https://docs.docker.com/desktop/multi-arch/
# docker buildx create --name mybuilder
# docker buildx use mybuilder
# docker buildx inspect --bootstrap
# docker buildx build --platform linux/amd64,linux/arm64,linux/arm/v7 -t daledavies/jump:v1.1.3 --push .

# PHP minor version to build against. The official php images publish a
# floating tag per minor version (e.g. "8.5-fpm-alpine") that is rebuilt for
# every PHP patch release and Alpine security update, so rebuilding this image
# is enough to pick up security fixes.
ARG PHP_VERSION=8.5

# Install composer dependencies using the same PHP version as the final image
# so composer's platform checks match what we will run on.
FROM --platform=$BUILDPLATFORM php:${PHP_VERSION}-cli-alpine AS builder
RUN apk add --no-cache git unzip
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
COPY jumpapp/ /app
WORKDIR /app
RUN composer install --no-dev \
  --optimize-autoloader \
  --no-interaction \
  --no-progress

# Use the official PHP-FPM image as the base, it already includes every
# extension Jump needs (curl, dom, fileinfo, json, openssl, session, xml, zlib).
FROM php:${PHP_VERSION}-fpm-alpine

WORKDIR /var/www/html

# Create a non-root user for running nginx and php.
RUN addgroup -S jumpapp && \
    adduser \
      --disabled-password \
      --ingroup jumpapp \
      --no-create-home \
      jumpapp

# Copy the built files from composer, chowning as jumpapp or they will
# be owned by root.
COPY --chown=jumpapp --from=builder /app /usr/src/jumpapp

# Install required packages and upgrade anything in the base image that has
# been patched since it was published.
RUN apk upgrade --no-cache && \
    apk add --no-cache \
      bash \
      curl \
      nginx

# Enable opcache if it isn't already built in (it is from PHP 8.5 onwards).
RUN php -m | grep -q "Zend OPcache" || docker-php-ext-enable opcache

# The official image installs php in /usr/local/bin, create symlink for
# anything expecting to find it in /usr/bin.
RUN ln -s -f /usr/local/bin/php /usr/bin/php

# Nginx config.
COPY docker/nginx.conf /etc/nginx/nginx.conf

# PHP/FPM config. Start from the recommended production php.ini, and replace
# the image's default pool config (which listens on TCP port 9000 and stops
# php-fpm from daemonizing) with our own.
RUN cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" && \
    rm -f /usr/local/etc/php-fpm.d/*.conf
COPY docker/fpm-pool.conf /usr/local/etc/php-fpm.d/www.conf
COPY docker/php.ini $PHP_INI_DIR/conf.d/custom.ini

COPY docker/entrypoint.sh /usr/local/bin/

# Create the cache directories and change owner of everything we need.
RUN mkdir /var/www/cache \
    && chown -R jumpapp:jumpapp /var/www/html /var/www/cache \
    && chmod +x /usr/local/bin/entrypoint.sh

# Expose the port we configured for nginx.
EXPOSE 8080

# The base image stops php-fpm with SIGQUIT, but our entrypoint runs nginx in
# the foreground so restore the default.
STOPSIGNAL SIGTERM

ENTRYPOINT ["entrypoint.sh"]

HEALTHCHECK --timeout=10s CMD curl --silent --fail http://127.0.0.1:8080/fpm-ping || exit 1
