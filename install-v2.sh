#!/bin/bash
# 1. Добавлена возможность работы скрипта через SSH
# 2. Добавлена возможность работы скрипта при ручной (без использования DHCP) настройке сетевого интерфейса
# 3.
# 7 Команда для запуска: bash <(curl -s#LJ https://raw.githubusercontent.com/esmelnikov/install-v2/main/install-v2.sh)

# var_scriptrepo="http://mirror.ttg.gazprom.ru/distribs"
var_scriptrepo="https://raw.githubusercontent.com/esmelnikov/install-v2/main"
var_version="02.03.03.22"
var_scriptname="install-v2.sh"
set -o pipefail # trace ERR through pipes
set -o errtrace # trace ERR through 'time command' and other functions
#set -o nounset # set -u : exit the script if you try to use an uninitialised variable
set -o errexit # set -e : exit the script if any statement returns a non-true return value
#set -x

if test "$(id -u)" -ne 0; then
	sudo "$0" "$1"
	exit $?
fi

####### Function definition #######

function pause() {
	read -rsp $'Press any key to continue...\n' -n 1
}

function countdown() {
	local start
	local time
	start="$(($(date '+%s') + $1))"
	while [ $start -ge "$(date +%s)" ]; do
		time="$(("$start" - $(date +%s)))"
		printf '%s\r' "Компьютер будет перезагружен через: $(date -u -d "@$time" +%H:%M:%S) сек."
		sleep 0.1
	done
}

function addsshuser() {
	local var_user="$1"
	shift
	local var_ssh_pub_key="$*"
	local var_password
	var_password=$(pwgen -sBy 20 1) && echo "Пароль пользователя $var_user сгенерирован"
	[[ ! $(getent passwd "$var_user") ]] || userdel -r "$var_user"
	adduser "$var_user" && echo "Пользователь $var_user создан успешно"
	echo "$var_user":"$var_password" | chpasswd && echo "Пароль пользователя $var_user установлен успешно"
	usermod -a -G wheel "$var_user" && echo "Пользователь $var_user успешно добавлен в группу wheel"
	var_password=""
	su - -c "[ -d .ssh ] || mkdir .ssh && chmod 700 .ssh" "$var_user" && echo "Установлены необходимые разрешения для каталога .ssh пользователя $var_user"
	su - -c "echo $var_ssh_pub_key > .ssh/authorized_keys" "$var_user" && echo "Открытый ключ для пользователя $var_user успешно добавлен"
	su - -c "chmod 600 .ssh/authorized_keys" "$var_user" && echo "Установлены необходимые разрешения для открытого ключа пользователя $var_user"
}

function setpassword() {
	local var_user="$1"
	local var_password
	local var_passrow
	local var_passphrase
	base64 -d "$var_installdir/words.enc" >"$var_installdir/words.orig"
	set +e
	set +o pipefail
	var_passrow=$(shuf "$var_installdir/words.orig" | head -n1)
	set -e
	set -o pipefail
	var_password=$(echo "$var_passrow" | cut -f1 -d'|')
	var_passphrase=$(echo "$var_passrow" | cut -f2 -d'|')
	echo "$var_user":"$var_password" | chpasswd
	echo "\"$HOSTNAME\";\"$var_user\";\"$var_password\";\"$var_passphrase\";\"$(date '+%d.%m.%Y %X')\"" >>"/home/$(logname)/cred-${HOSTNAME^^}.txt"
	chown "$(logname):" "/home/$(logname)/cred-${HOSTNAME^^}.txt"
	rm -f "$var_installdir/words.orig"
}

function setpasswordgrub() {
	local var_password
	local var_user
	local var_passphrase
	var_user=boot
	var_password=$(pwgen -Bc 8 1) && echo "Пароль для загрузчика grub сгенерирован"
	var_passphrase=""
	cat >/etc/grub.d/50_password <<-EOF_CONF
		#!/bin/sh
		cat << EOF
		set superusers="boot"
		password_pbkdf2 boot $(echo -e "$var_password\n$var_password" | LANG=C grub-mkpasswd-pbkdf2 | sed -rn 's,^.* (grub\.pbkdf2.*)$,\1,p')
		EOF
	EOF_CONF
	chmod 700 /etc/grub.d/50_password
	grub-mkconfig -o /boot/grub/grub.cfg
	echo "\"$HOSTNAME\";\"$var_user\";\"$var_password\";\"$var_passphrase\";\"$(date '+%d.%m.%Y %X')\"" >>"/home/$(logname)/cred-${HOSTNAME^^}.txt"
}

function cleanup() {
	[[ ! -f "$var_stage" ]] && exit 0
	if [[ "$(cat "$var_stage")" = 0 ]]; then
		[[ -d "${var_installdir}" ]] && rm -rf "$var_installdir"
		[[ -f "$var_homedir/$var_scriptname" ]] && rm -f "$var_homedir/$var_scriptname"
	fi
	echo 'Function cleanup complete'
}

function error() {
	local last_exit_status="$?"
	local parent_lineno="$1"
	local message="${2:-(no message ($last_exit_status))}"
	local code="${3:-$last_exit_status}"
	if [[ -n "$message" ]]; then
		echo "ОШИБКА В СТРОКЕ ${parent_lineno}: ${message}; СТАТУС ВЫХОДА ${code}"
	else
		echo "ОШИБКА В СТРОКЕ ${parent_lineno}; СТАТУС ВЫХОДА ${code}"
	fi
	#	if ((  "$(cat "$var_stage")" > 4 )) ; then
	#		echo "Версия скрипта: $var_version"
	#		credential=$(base64 -d "$var_installdir/credential")
	#		echo -n "Имя пользователя: $credential" | cut -d'|' -f1
	#		echo ""
	#		mail < "$var_logfile" -s "Installation error on ${HOSTNAME^^}" "altinstall@ttg.gazprom.ru"
	#	fi
	exit "${code}"
}

function escape {
	clear
	echo "Выполнение скрипта прервано пользователем..."
	exit 0
}

function message {
	local var_exitcode
	local var_title
	set +e
	trap '' ERR
	[[ "$1" == "--warning" ]] && var_title="Предупреждение[!]"
	[[ "$1" == "--error" ]] && var_title="Ошибка[!!!]"
	if [[ "$DISPLAY" ]]; then
		zenity --modal "$1" --width 300 --height=100 --text="$2"
		var_exitcode=$?
	else
		if [ "$(command -v dialog)" ]; then
			dialog --clear --title "$var_title" --msgbox "$2" 10 42
			var_exitcode=$?
		else
			echo "$2"
		fi
	fi
	if [[ "$var_exitcode" = 255 ]] || [[ "$var_exitcode" = 1 ]]; then
		escape
	fi
	set -e
	trap 'error ${LINENO}' ERR
}

function requestcred() {
	var_exitcode="200"
	while [ "$var_exitcode" -ne 0 ]; do
		trap '' ERR
		set +e
		local var_credential
		local var_username
		local var_password
		if [[ "$DISPLAY" ]]; then
			var_credential=$(zenity --modal --password --username)
			var_exitcode=$?
		else
			backtitle="Ввод данных учетной записи для присоединения компьютера к домену"
			var_credential=$(
				dialog --clear --no-cancel --title "Укажите имя пользователя и пароль" \
					--backtitle "$backtitle" \
					--insecure --output-separator "|" \
					--mixedform "Используйте клавиши курсора для перемещения между полями и [Enter] для подтверждения" \
					10 48 0 "Username:" 1 1 "" 1 10 30 0 0 "Password:" 2 1 "" 2 10 30 0 1 2>&1 >/dev/tty
			)
			var_exitcode=$?
			var_credential=${var_credential%?}
		fi
		if [[ "$var_exitcode" = 255 ]] || [[ "$var_exitcode" = 1 ]]; then
			escape
		fi
		clear
		var_username=$(echo -n "$var_credential" | cut -d"|" -f1)
		var_password=${var_credential#*|}
		####### For debug #######
		echo "$var_username"
		echo "$var_password"
		if [ "$var_username" = "" ] || [ "$var_password" = "" ] || [ "$var_credential" = "" ]; then
			message "--warning" "Имя пользователя и пароль должны быть указаны"
			var_exitcode=200
			continue
		fi
	done
	trap 'error ${LINENO}' ERR
	set -e
	cat >"$var_installdir/credential" <<-EOF
		$(printf "%s" "$var_credential" | base64)
	EOF
}

####### End of function definition #######

trap 'error ${LINENO}' ERR
trap 'cleanup' EXIT

var_scriptdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
var_homedir="/home/$(logname)"
var_installdir="/home/$(logname)/.install"
var_stage="$var_installdir/.stage"
var_os="$var_installdir/.os"

if [[ ! "$(command -v shutdown)" ]]; then
	clear
	message "--error" "Скрипт запущен некорректно. В дистрибутивах ALT для получения прав root следует \
	использовать команду su- (su с \"минусом\"). Выполните команду su- в терминале, а затем запустите скрипт."
	exit 0
fi

if [ -f "/var/log/gty/.install/complete.log" ]; then
	clear
	message "--error" "Вы пытаетесь запустить скрипт повторно, после успешного завершения."
	exit 0
fi

echo "Значения переменных..."
echo "Скрипт расположен в каталоге: $var_scriptdir"
echo "Скрипт запущен пользователем: $(logname)"
echo "Скрипт выполняется с правами пользователя: $(whoami)"
echo "Домашний каталог пользователя запустившего скрипт: $var_homedir"
echo "Переменная окружения \$HOME: $HOME"
echo "Каталог установки: $var_installdir"
echo "Версия скрипта: $var_version"
#echo "Шаг установки: $var_stage"

if [[ ! -f "$var_stage" ]]; then
	echo "ШАГ ПОДГОТОВКА начало..."
	echo "Создание каталога установки..."
	[[ -d "$var_installdir" ]] || (mkdir "$var_installdir" && echo "Каталог установки успешно создан")
	grep 'CPE_NAME=' '/etc/os-release' | cut -d':' -f4 | tee "$var_os"
	if [[ "$(cat "$var_os")" = "server" ]]; then
		#echo "Отключение всех существующих репозиториев"
		#apt-repo rm all
		#echo "Предварительная настройка локального репозитория..."
		#var_branch=$(grep 'CPE_NAME=' '/etc/os-release' | cut -d':' -f5 | cut -d'.' -f1)
		#var_repo="mirorr-au"
		#cat >"/etc/apt/sources.list.d/local.list" <<-EOF
		#	rpm [p${var_branch}] http://${var_repo}.ttg.gazprom.ru/pub/distributions/ALTLinux p${var_branch}/branch/x86_64 classic
		#	rpm [p${var_branch}] http://${var_repo}.ttg.gazprom.ru/pub/distributions/ALTLinux p${var_branch}/branch/x86_64-i586 classic
		#	rpm [p${var_branch}] http://${var_repo}.ttg.gazprom.ru/pub/distributions/ALTLinux p${var_branch}/branch/noarch classic
		#EOF
		echo "Установка компонентов, необходимых для работы скрипта..."
		echo "Обновление индексов пакетов..."
		apt-get update -q
		apt-get install -yq sudo
		apt-get install -yq dialog
		# apt-get install task-auth-ad-sssd
	fi
	echo "Загрузка скрипта для локального запуска..."
	[[ ! -f "$var_stage" ]] && curl -# -o "$var_homedir/$var_scriptname" "$var_scriptrepo/$var_scriptname" || echo "Ошибка загрузки файла $var_scriptname"
	chown "$(logname):" "$var_homedir/$var_scriptname"
	chmod +x "$var_homedir/$var_scriptname"
	echo "ШАГ ПОДГОТОВКА завершен..." && echo "0" >"$var_stage" && echo "Статус установки сохранен..."
	exec "$var_homedir/$var_scriptname"
fi

# ШАГ 0 НАЧАЛО
if [[ "$(cat "$var_stage")" = 0 ]]; then
	echo "ШАГ $(cat "$var_stage") начало..."
	#echo "Скрипт расположен в каталоге: $var_scriptdir"
	#echo "Скрипт запущен пользователем: $(logname)"
	#echo "Скрипт выполняется с правами пользователя: $(whoami)"
	#echo "Переменная окружения \$HOME: $HOME"

	if [[ "$(cat "$var_os")" = "workstation" ]]; then
		# Пакеты для установки из репозитория на ОС Alt Workstation
		cat >"$var_installdir/installreppkgs" <<-EOF
			pcsc-lite-ccid
			pcsc-tools-gui
			stunnel4
			libidn1.34
			pwgen
			adcli
			alterator-audit
			alterator-grub
			gpupdate
			alterator-gpupdate
			alt-csp-cryptopro
			LibreOffice-plugin-altcsp
			mate-file-manager-actions
			evolution
			evolution-ews
			pidgin
			pidgin-sipe
			pidgin-libnotify
			chromium-gost
			remmina
			remmina-plugins-rdp
			remmina-plugins-vnc
			easypaint
			libsasl2-3
			postfix-tls
			postfix-cyrus
			fonts-ttf-ms
			doublecmd
			gtk-theme-windows-10
		EOF
		# Дополнительные сторонние пакеты rpm для установки
		cat >"$var_installdir/installextpkgs" <<-EOF
			ICAClient-rhel-13.10.0.20-0.x86_64.rpm
			ctxusb-2.7.20-1.x86_64.rpm
			r7-office.rpm
			ifd-rutokens_1.0.4_1.x86_64.rpm
		EOF
		# Пакеты для удаления apt-indicator
		cat >"$var_installdir/delpkgs" <<-EOF
			mate-file-manager-share
			libnss-mdns
			smtube
			gnome-software
			openct
			pcsc-lite-openct
		EOF
	else
		# Пакеты для установки на Alt Server
		cat >"$var_installdir/installreppkgs" <<-EOF
			task-auth-ad-sssd
			libsasl2-3
			postfix-tls
			postfix-cyrus
		EOF
	fi

	echo "Загрузка настроек для скрипта..."
	curl -# -o "$var_installdir/setting.zip" "$var_scriptrepo/setting.zip" || echo "Ошибка загрузки файла setting.zip"
	echo "Извлечение архива..."
	unzip -qo "$var_installdir/setting.zip" -d "$var_installdir" && echo "Архив setting.zip успешно распакован"

	####### Choise filial #######
	var_menu=(
		AU "Администрация Общества"
		BU "Белоярское отделение УОВОФ"
		U2 "Белоярское УАВР"
		T2 "Белоярское УТТиСТ"
		BB "Бобровское ЛПУМГ"
		WK "Верхнеказымское ЛПУМГ"
		IW "Ивдельское ЛПУМГ"
		IB "ИТЦ Белоярский"
		IK "ИТЦ Краснотурьинск"
		IN "ИТЦ Надым"
		IY "ИТЦ Югорск"
		KZ "Казымское ЛПУМГ"
		KP "Карпинское ЛПУМГ"
		KM "Комсомольское ЛПУМГ"
		KT "Краснотурьинское ЛПУМГ"
		FO "Культурно-спортивный комплекс НОРД"
		LU "Лонг-Юганское ЛПУМГ"
		NA "Надымское ЛПУМГ"
		NK "Надымское отделение УОВОФ"
		U1 "Надымское УАВР"
		T1 "Надымское УТТиСТ"
		NT "Нижнетуринское ЛПУМГ"
		LA "Нижнетуринское ЛПУМГ (Лялинская промплощадка)"
		NU "Ново-Уренгойское ЛПУМГ (Ново-Уренгойская промплощадка)"
		PU "Ново-Уренгойское ЛПУМГ (Пуровская промплощадка)"
		NY "Ныдинское ЛПУМГ"
		OK "Октябрьское ЛПУМГ"
		PA "Пангодинское ЛПУМГ"
		PE "Пелымское ЛПУМГ"
		PG "Перегребненское ЛПУМГ"
		PH "Правохеттинское ЛПУМГ"
		B2 "Приобское УМТСиК"
		PZ "Приозерное ЛПУМГ"
		PN "Пунгинское ЛПУМГ"
		PF "Санаторий-профилакторий"
		SR "Сорумское ЛПУМГ"
		SN "Сосновское ЛПУ"
		SO "Сосьвинское ЛПУМГ"
		TG "Таежное ЛПУМГ"
		UK "Управление организации восстановления основных фондов (УОВОФ)"
		CU "Управление по эксплуатации зданий и сооружений (УЭЗиС)"
		US "Управление связи"
		UR "Уральское ЛПУМГ"
		KI "Учебно-производственный центр Игрим"
		KK "Учебно-производственный центр Югорск"
		U3 "Югорское УАВР"
		B1 "Югорское УМТСиК"
		T3 "Югорское УТТиСТ"
		YG "Ягельное ЛПУМГ"
		YS "Ямбуpгское ЛПУМГ (Елец)"
		YA "Ямбуpгское ЛПУМГ (Пангоды)"
	)

	var_title="Выбор филиала"
	var_text="Для корректной настройки АРМ необходимо выбрать филиал Общества"
	if [[ "$DISPLAY" ]]; then
		var_column1="Код"
		var_column2="Филиал"
		var_exitcode=200
		while [ "$var_exitcode" -ne 0 ]; do
			set +e
			trap '' ERR
			var_filial=$(zenity --modal --list --title "$var_title" --text="$var_text" --width 510 --height=400 --hide-column=1 --column="$var_column1" --column="$var_column2" "${var_menu[@]}")
			var_exitcode=$?
			set -e
			trap 'error ${LINENO}' ERR
			[[ "$var_exitcode" = 255 ]] || [[ "$var_exitcode" = 1 ]] && escape
			if [[ $var_filial = "" ]]; then
				message "--warning" "Необходимо выбрать филиал."
				var_exitcode=200
				continue
			fi
		done
	else
		height=18
		width=73
		choice_height=11
		backtitle="Индивидуальные настройки АРМ филиала"
		set +e
		trap '' ERR
		var_filial=$(dialog --clear --no-tags --cancel-label "Выход" --backtitle "$backtitle" --title "$var_title" --menu "$var_text" "$height" "$width" "$choice_height" "${var_menu[@]}" 2>&1 >/dev/tty)
		var_exitcode=$?
		set -e
		trap 'error ${LINENO}' ERR
		[[ "$var_exitcode" = 255 ]] || [[ "$var_exitcode" = 1 ]] && escape
		clear
	fi

	####### For debug #######
	echo "${var_filial}"

	base64 -d "$var_installdir/setting.enc" >"$var_installdir/setting.orig"
	var_filialcode=$(grep -e "^${var_filial}" "$var_installdir/setting.orig" | cut -d";" -f2)
	var_domain=$(grep -e "^${var_filial}" "$var_installdir/setting.orig" | cut -d";" -f3)
	var_usergrp=$(grep -e "^${var_filial}" "$var_installdir/setting.orig" | cut -d";" -f4)
	var_fadmingrp=$(grep -e "^${var_filial}" "$var_installdir/setting.orig" | cut -d";" -f5)
	var_fsvcgrp=$(grep -e "^${var_filial}" "$var_installdir/setting.orig" | cut -d";" -f6)
	var_gadmingrp=$(grep -e "^${var_filial}" "$var_installdir/setting.orig" | cut -d";" -f7)
	var_kavsshkey=$(grep -e "^${var_filial}" "$var_installdir/setting.orig" | cut -d";" -f8)
	var_repo=$(grep -e "^${var_filial}" "$var_installdir/setting.orig" | cut -d";" -f9)
	var_email=$(grep -e "^${var_filial}" "$var_installdir/setting.orig" | cut -d";" -f10)
	var_mailsrv=$(grep -e "^${var_filial}" "$var_installdir/setting.orig" | cut -d";" -f11)
	var_filialready=$(grep -e "^${var_filial}" "$var_installdir/setting.orig" | cut -d";" -f12)
	[[ $var_repo = "" ]] && var_repo=$(grep -e "^AU" "$var_installdir/setting.orig" | cut -d";" -f9)
	[[ $var_mailsrv = "" ]] && var_mailsrv=$(grep -e "^AU" "$var_installdir/setting.orig" | cut -d";" -f11)
	echo "$var_filialcode" >"$var_installdir/filialcode"
	echo "$var_domain" >"$var_installdir/domain"
	echo "$var_fadmingrp" >"$var_installdir/fadmingrp"
	echo "$var_fsvcgrp" >"$var_installdir/fsvcgrp"
	echo "$var_gadmingrp" >"$var_installdir/gadmingrp"
	echo "$var_kavsshkey" >"$var_installdir/kavsshkey"
	echo "$var_email" >"$var_installdir/email"
	echo "$var_mailsrv" >"$var_installdir/mailsrv"
	var_branch=$(grep -oE '^VERSION=.*' /etc/os-release | sed -e 's/^VERSION="//g' -e 's/"$//g' | cut -d"." -f1)
	echo "$var_branch" >"$var_installdir/branch"
	cat >"$var_installdir/77-kaspersky" <<-EOF
		%$var_fsvcgrp ALL=(ALL) NOPASSWD: ALL
	EOF
	cat >"$var_installdir/role" <<-EOF
		$var_usergrp:users
		$var_fadmingrp:localadmins
		$var_gadmingrp:localadmins
	EOF
	# Можно сохранять сразу в настройки репозиториев
	cat >"$var_installdir/local.list" <<-EOF
		rpm [p${var_branch}] http://${var_repo}.ttg.gazprom.ru/pub/distributions/ALTLinux p${var_branch}/branch/x86_64 classic
		rpm [p${var_branch}] http://${var_repo}.ttg.gazprom.ru/pub/distributions/ALTLinux p${var_branch}/branch/x86_64-i586 classic
		rpm [p${var_branch}] http://${var_repo}.ttg.gazprom.ru/pub/distributions/ALTLinux p${var_branch}/branch/noarch classic
	EOF

	rm -f "$var_installdir/setting.orig"

	####### For debug #######
	var_filialready=1
	if [[ $var_filialready = 0 ]]; then
		message "--warning" "Для настройки компьютера Alt Linux вашего филиала необходимо предоставить дополнительные данные. Информацию можно получить обратившись по адресу: es.melnikov@ttg.gazprom.ru"
		clear
		exit 0
	fi

	####### Enter hostname #######

	var_cod=$(cat "$var_installdir/filialcode")
	var_title="Имя компьютера"
	var_text="Введите имя компьютера"
	var_exitcode=200
	if [[ "$(cat "$var_os")" = "workstation" ]]; then
		var_prefix=WS
		var_symbol=4
		var_number=3
		var_template=L001
	else
		var_prefix=SV
		var_symbol=5
		var_number=2
		var_template=L01
	fi
	while [ "$var_exitcode" -ne 0 ]; do
		set +e
		trap '' ERR
		if [[ "$DISPLAY" ]]; then
			var_hostname=$(zenity --modal --entry --entry-text="$var_prefix-$var_cod-$var_template" --title "$var_title" --text "$var_text")
		else
			var_hostname=$(dialog --clear --max-input 15 --no-cancel --trim --title "$var_title" --inputbox "$var_text" 8 40 "$var_prefix-$var_cod-$var_template" 2>&1 >/dev/tty)
		fi
		set -e
		trap 'error ${LINENO}' ERR
		var_exitcode=$?
		echo $var_exitcode
		if [[ "$var_exitcode" = 255 ]] || [[ "$var_exitcode" = 1 ]]; then
			escape
		fi
		var_hostname=${var_hostname^^}
		if [[ $var_hostname = "" ]]; then
			message "--error" "Имя компьютера должно быть указано"
			var_exitcode=200
			continue
		fi
		if [[ "$(echo -n "$var_hostname" | wc -m)" -gt 15 ]]; then
			message "--error" "Имя компьютера не может содержать более 15 символов"
			var_exitcode=200
			continue
		else
			if ! grep -E "^${var_prefix}-${var_cod}-[A-Z]?{${var_symbol}}-?[L][0-9]{${var_number}}$" <<<"$var_hostname"; then
				message "--error" "Имя компьютера должно соответствовать регламенту. Шаблон для вашего филиала:\n${var_prefix}-${var_cod}-$var_template или ${var_prefix}-${var_cod}-S{1...${var_symbol}}-$var_template,\nгде S-символы от A до Z"
				var_exitcode=200
				continue
			fi
		fi
	done
	clear

	echo "${var_exitcode}"
	echo "${var_hostname}"
	####### Enter hostname #######

	if [[ "$(cat "$var_os")" = "workstation" ]]; then
		var_msgou="WorkstationsLnx"
	else
		var_msgou="ServersLnx"
	fi
	message "--warning" "Перед продолжением работы УБЕДИТЕСЬ, что в организационной единице $var_msgou вашего филиала СОЗДАНА учетная запись компьютера с именем  $var_hostname"
	clear
	cat >"$var_installdir/hostname" <<-EOF
		${var_hostname,,}
	EOF
	requestcred

	if systemctl is-active --quiet NetworkManager; then
		# For Network manager
		cat >"/etc/NetworkManager/dispatcher.d/99-fix-slow-dns" <<-EOF
			#!/bin/bash
			# from install-v2.sh script
			# 15/02/2023
			mapfile -t var_resolvfiles <<< "\$(find '/etc/net/ifaces/' -name 'resolv.conf')"
			var_resolvfiles+=(/etc/resolv.conf /run/NetworkManager/resolv.conf /run/NetworkManager/no-stub-resolv.conf)
			for var_resolvfiles in "\${var_resolvfiles[@]}"; do
				[[ ! -f "\$var_resolvfiles" ]] && continue
				if grep "^search" "\$var_resolvfiles"; then
					sed -i "s/^search.*/search $(cat "$var_installdir/domain") ttg.gazprom.ru/1" "\$var_resolvfiles"
				else
					echo "search $(cat "$var_installdir/domain") ttg.gazprom.ru" >>"\$var_resolvfiles"
				fi
				if grep "^options single-reques.*" "\$var_resolvfiles"; then
					sed -i "s/^options single-reques.*/options single-request-reopen/1" "\$var_resolvfiles"
				else
					echo "options single-request-reopen" >>"\$var_resolvfiles"
				fi
			done
			/sbin/update_chrooted conf
			exit 0
		EOF
		chmod +x "/etc/NetworkManager/dispatcher.d/99-fix-slow-dns"
		nmcli con reload
		echo "Ожидание инициализации сети..."
		nm-online -t 60
		sleep 5
	else
		# For etcnet
		cat >"/lib/dhcpcd/dhcpcd-hooks/99-fix-slow-dns" <<-EOF
			# from install-v2.sh script
			# 03/03/2023
			[ "\$if_up" = "true" ] && echo 'options single-request-reopen' | /sbin/resolvconf -a "\${interface}.options" > /dev/null 2>&1
			mapfile -t var_resolvfiles <<< "\$(find '/etc/net/ifaces/' -name 'resolv.conf')"
			for var_resolvfiles in "\${var_resolvfiles[@]}"; do
				[[ ! -f "\$var_resolvfiles" ]] && continue
				if grep "^search" "\$var_resolvfiles"; then
					sed -i "s/^search.*/search $(cat "$var_installdir/domain") ttg.gazprom.ru/1" "\$var_resolvfiles"
				else
					echo "search $(cat "$var_installdir/domain") ttg.gazprom.ru" >>"\$var_resolvfiles"
				fi
				if grep "^options single-reques.*" "\$var_resolvfiles"; then
					sed -i "s/^options single-reques.*/options single-request-reopen/1" "\$var_resolvfiles"
				else
					echo "options single-request-reopen" >>"\$var_resolvfiles"
				fi
			done
			/sbin/update_chrooted conf
		EOF
		/sbin/update_chrooted conf
		chmod +x /lib/dhcpcd/dhcpcd-hooks/99-fix-slow-dns
		chmod 444 /lib/dhcpcd/dhcpcd-hooks/99-fix-slow-dns
	fi

	pause

	if [[ "$var_cod" != "NY" ]]; then var_repo="mirror"; fi
	echo "Загрузка необходимых для установки компонентов..."
	curl -#C - -o "$var_installdir/linux-amd64.tgz" "http://${var_repo}.ttg.gazprom.ru/distribs/criptopro50r3/linux-amd64.tgz" || echo "Ошибка загрузки файла linux-amd64.tgz"
	curl -#C - -o "$var_installdir/jacartauc_2.13.12.3203_alt_x64.zip" "http://${var_repo}.ttg.gazprom.ru/distribs/jacarta213/jacartauc_2.13.12.3203_alt_x64.zip" || echo "Ошибка загрузки файла jacartauc_2.13.12.3203_alt_x64.zip"
	curl -#C - -o "$var_installdir/ius.zip" "http://${var_repo}.ttg.gazprom.ru/distribs/ius.zip" || echo "Ошибка загрузки файла ius.zip"
	curl -#C - -o "$var_installdir/ca.zip" "http://${var_repo}.ttg.gazprom.ru/distribs/ca.zip" || echo "Ошибка загрузки файла ca.zip"
	echo "Загрузка компонентов успешно завершена..."
	echo "Загрузка дополнительных сторонних пакетов rpm..."
	var_installextpkgs=$(tr '\n' ' ' <"$var_installdir/installextpkgs")
	for i in $var_installextpkgs; do
		echo "Загрузка пакета $i..."
		curl -#C - -o "$var_installdir/$i" "http://${var_repo}.ttg.gazprom.ru/distribs/rpm/$i" || echo "Ошибка загрузки файла $i"
		echo "Пакет $i успешно загружен..."
	done
	echo "ШАГ 0 завершен..." && echo "1" >"$var_stage" && echo "Статус установки сохранен..."
fi
# ШАГ 0 КОНЕЦ

echo "Test"
pause

echo workstation >"${var_os}"
var_cod="AU"

sleep 1d

echo "Все предварительные условия соблюдены"
sleep 1d

var_scriptdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
var_homedir="/home/$(logname)"
var_installdir="/home/$(logname)/.install"
var_stage="$var_installdir/.stage"
var_os="$var_installdir/.os"

echo "Скрипт расположен в каталоге: $var_scriptdir"
echo "Скрипт запущен пользователем: $(logname)"
echo "Скрипт выполняется с правами пользователя: $(whoami)"
echo "Переменная окружения \$HOME: $HOME"

echo "Значения переменных..."
echo "var_scriptdir: $var_scriptdir"
echo "var_homedir: $var_homedir"
echo "var_installdir: $var_installdir"
echo "var_stage: $var_stage"

if [ ! -f "/var/log/gty/.install/complete.log" ]; then
	var_message="Вы пытаетесь запустить скрипт повторно, после успешного завершения."
	message "--warning" "$var_message"
fi

echo "Скрипт расположен в каталоге: $var_scriptdir"
echo "Скрипт запущен пользователем: $(logname)"
echo "Скрипт выполняется с правами пользователя: $(whoami)"
echo "Переменная окружения \$HOME: $HOME"

echo "Значения переменных..."
echo "var_scriptdir: $var_scriptdir"
echo "var_homedir: $var_homedir"
echo "var_installdir: $var_installdir"
echo "var_stage: $var_stage"

####### Choise filial #######

echo '222222'
echo '222222'
echo '222222'
echo '222222'
echo '222222'
echo '222222'
#[[ $? = 77 ]] && echo 'Вы завершили работу скрипта...' && exit 0

#echo "Exit function code" $?
