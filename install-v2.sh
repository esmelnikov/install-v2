#!/bin/bash
# 1. Добавлена возможность работы скрипта через SSH
# 2. Добавлена возможность работы скрипта при ручной (без использования DHCP) настройке сетевого интерфейса
# 3.
# 7 Команда для запуска: bash <(curl -#LJ https://raw.githubusercontent.com/esmelnikov/install-v2/main/install-v2.sh)

var_version="02.24.02.23"
var_scriptname="install.sh"
set -o pipefail # trace ERR through pipes
set -o errtrace # trace ERR through 'time command' and other functions
#set -o nounset   ## set -u : exit the script if you try to use an uninitialised variable
set -o errexit ## set -e : exit the script if any statement returns a non-true return value
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
	#	[[ ! -f "$var_stage" ]] && exit 0
	#	if [[ "$(cat "$var_stage")" = 0 ]]; then
	#		[[ -f "$var_stage" ]] && rm -f "$var_stage"
	#		[[ -f "$var_homedir/$var_scriptname" ]] && rm -f "$var_homedir/$var_scriptname"
	#	fi
	echo 'CLEANUP'
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
	echo "Вы завершили работу скрипта..."
	exit 0
}

function message {
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
			echo "$var_message"
		fi
	fi
	if [[ "$var_exitcode" = 255 ]] || [[ "$var_exitcode" = 1 ]]; then
		escape
	fi
	set -e
	trap 'error ${LINENO}' ERR
	var_title=""
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
		#echo "$var_username"
		#echo "$var_password"
		if [ "$var_username" = "" ] || [ "$var_password" = "" ] || [ "$var_credential" = "" ]; then
			message "--warning" "Имя пользователя и пароль должны быть указаны"
			var_exitcode=200
			continue
		fi
	done
	trap 'error ${LINENO}' ERR
	set -e
	echo "End of function"
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


if [[ ! "$(command -v shutdown)" ]]; then
	message "--warning" "Скрипт запущен некорректно. В дистрибутивах ALT для получения прав root следует \
	использовать команду su- (su с \"минусом\"). Выполните команду su- в терминале, а затем запустите скрипт."
	exit 0
fi

if [ -f "/var/log/gty/.install/complete.log" ]; then
	message "--warning" "Вы пытаетесь запустить скрипт повторно, после успешного завершения."
	exit 0
fi

echo "Значения переменных..."
echo "Скрипт расположен в каталоге: $var_scriptdir"
echo "Скрипт запущен пользователем: $(logname)"
echo "Скрипт выполняется с правами пользователя: $(whoami)"
echo "Домашний каталог пользователя запустившего скрипт: $var_homedir"
echo "Переменная окружения \$HOME: $HOME"
echo "Каталог установки: $var_installdir"
echo "Шаг установки: $var_stage"



pause


var_filialready=1
if [[ $var_filialready = 0 ]]; then
	var_message="Для настройки компьютера Alt Linux вашего филиала необходимо предоставить дополнительные данные. Информацию можно получить обратившись по адресу: es.melnikov@ttg.gazprom.ru"
	message "--warning" "$var_message"
	exit 0
fi

var_os="$var_installdir/.os"
echo workstation >"${var_os}"
var_cod="AU"

####### Enter hostname #######
#var_cod=$(cat "$var_installdir/filialcode")
var_title="Имя компьютера"
var_text="Введите имя компьютера"
var_exitcode="200"
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
		var_exitcode="200"
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

if [[ ! -f "$var_stage" ]]; then
	echo "ШАГ ПОДГОТОВКА начало..."
	echo "Создание каталога установки..."
	[[ -d "$var_installdir" ]] || (mkdir "$var_installdir" && echo "Каталог установки успешно создан")

	grep 'CPE_NAME=' '/etc/os-release' | cut -d':' -f4 | tee "$var_os"

	if [[ "$(cat "$var_os")" = "server" ]]; then
		echo "Отключение всех существующих репозиториев"
		apt-repo rm all
		echo "Предварительная настройка локального репозитория..."
		var_branch=$(grep 'CPE_NAME=' '/etc/os-release' | cut -d':' -f5 | cut -d'.' -f1)
		var_repo="mirorr-au"
		cat >"/etc/apt/sources.list.d/local.list" <<-EOF
			rpm [p${var_branch}] http://${var_repo}.ttg.gazprom.ru/pub/distributions/ALTLinux p${var_branch}/branch/x86_64 classic
			rpm [p${var_branch}] http://${var_repo}.ttg.gazprom.ru/pub/distributions/ALTLinux p${var_branch}/branch/x86_64-i586 classic
			rpm [p${var_branch}] http://${var_repo}.ttg.gazprom.ru/pub/distributions/ALTLinux p${var_branch}/branch/noarch classic
		EOF
		echo "Установка компонентов, необходимых для работы скрипта..."
		echo "Обновление индексов пакетов..."
		apt-get update -q
		apt-get install -yq sudo
		apt-get install -yq dialog
		# apt-get install task-auth-ad-sssd
	fi
	echo "Загрузка скрипта для локального запуска..."
	[[ ! -f "$var_stage" ]] && curl -# -o "$var_homedir/$var_scriptname" "http://mirror.ttg.gazprom.ru/distribs/$var_scriptname" || echo "Ошибка загрузки файла $var_scriptname"
	chown "$(logname):" "$var_homedir/$var_scriptname"
	chmod +x "$var_homedir/$var_scriptname"
	echo "ШАГ ПОДГОТОВКА завершен..." && echo "0" >"$var_stage" && echo "Статус установки сохранен..."
	exec "$var_homedir/$var_scriptname"
fi

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
if [ "$DISPLAY" ]; then
	var_column1="Код"
	var_column2="Филиал"
	var_exitcode="200"
	while [ "$var_exitcode" -ne 0 ]; do
		var_filial=$(zenity --modal --list --title "$var_title" --text="$var_text" --width 510 --height=400 --hide-column=1 --column="$var_column1" --column="$var_column2" "${var_menu[@]}")
		var_exitcode=$?
		[[ "$var_exitcode" = "1" ]] && echo "Вы завершили работу скрипта..." && exit 0
		echo "${var_exitcode}"
		echo "${var_exitcode}"
		[[ $var_filial = "" ]] && var_exitcode="200" && zenity --modal --warning --width 300 --height=100 --text="Необходимо выбрать филиал." && continue
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
	[[ "$var_exitcode" = 255 ]] || [[ "$var_exitcode" = 1 ]] && clear && echo "Вы завершили работу скрипта..." && exit 0
	clear
fi
echo "${var_filial}"
####### Choise filial #######

echo '222222'
echo '222222'
echo '222222'
echo '222222'
echo '222222'
echo '222222'
#[[ $? = 77 ]] && echo 'Вы завершили работу скрипта...' && exit 0

#echo "Exit function code" $?
