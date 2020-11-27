FROM php:7.4-cli

WORKDIR /app

RUN apt-get update && apt-get install -y sudo && rm -rf /var/lib/apt/lists/*

COPY index.php index.php
COPY init /usr/local/bin/

ENTRYPOINT ["/usr/local/bin/init"]

CMD [ "php", "-S", "0.0.0.0:8080" ]
