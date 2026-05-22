#!/bin/bash

set -e

# функция для проброса докер команды в dind
doc() {
    # 1. Проверяем, передан ли номер агента
    if [ "$1" != "1" ] && [ "$1" != "2" ]; then
        echo "Ошибка: Первым аргументом нужно указать номер агента (1 или 2)."
        echo "Пример: doc 1 ps"
        return 1
    fi

    # 2. Запоминаем номер агента, порт и формируем переменные
    local AGENT_NUM="$1"
    local PORT=$([ "$AGENT_NUM" = "1" ] && echo "2376" || echo "2377")
    local CONTAINER_NAME="lr-jenkins-jenkins-agent${AGENT_NUM}-1"
    local CERTS_DIR="certs${AGENT_NUM}"

    # 3. Сдвигаем аргументы (удаляем номер агента)
    shift

    # 4. Создаем изолированную папку для сертификатов конкретного агента
    mkdir -p "$CERTS_DIR"

    # 5. Копируем сертификаты из правильного контейнера
    [ ! -f "$CERTS_DIR/ca.pem" ]   && docker cp "${CONTAINER_NAME}:/certs/client/ca.pem" "$CERTS_DIR/ca.pem"
    [ ! -f "$CERTS_DIR/cert.pem" ] && docker cp "${CONTAINER_NAME}:/certs/client/cert.pem" "$CERTS_DIR/cert.pem"
    [ ! -f "$CERTS_DIR/key.pem" ]  && docker cp "${CONTAINER_NAME}:/certs/client/key.pem" "$CERTS_DIR/key.pem"

    # 6. Выполняем docker-команду с динамическим портом
    DOCKER_HOST="tcp://localhost:${PORT}" DOCKER_TLS_VERIFY=1 DOCKER_CERT_PATH="$PWD/$CERTS_DIR" docker "$@"
}

getpasswd(){
  local CONTAINER_NAME="lr-jenkins-jenkins-master-1"

  echo "Если пусто попробуй еще раз."

  # Пытаемся получить пароль из контейнера
  ADMIN_PASSWORD=$(docker exec "$CONTAINER_NAME" cat /var/jenkins_home/secrets/initialAdminPassword 2>/dev/null)

  # Проверяем, удалось ли получить пароль (строка не должна быть пустой)
  if [ -z "$ADMIN_PASSWORD" ]; then
    echo -e "\033[1;31m❌ Ошибка: Не удалось проинициализировать пароль.\033[0m"
    echo "Возможно, контейнер ещё запускается или файл уже был удален после первой настройки."
    echo -e "👉 \033[1;33mПопробуйте еще раз через некоторое время.\033[0m"
    return 1
  fi

  # Если всё успешно, выводим пароль
  echo "🔐 ВАШ ПАРОЛЬ ДЛЯ ВХОДА (логин: admin):"
  echo -e "\033[1;32m$ADMIN_PASSWORD\033[0m"
}

# Функция для сборки контейнеров
build() {
    echo "Сборка контейнеров..."
    docker compose -f docker-compose.yml build
}

# Функция для старта контейнеров
start() {
    local HOSTS_FILE="/etc/hosts"
    local TARGET_HOST="jenkins-master"
    local TUNNEL_CMD="ssh -C -L jenkins-master:8080:localhost:8080 dev-vsrv09"

    echo -e "\n\033[1;33m⚠️  Внимание: В файле $HOSTS_FILE следует добавить запись для хоста '$TARGET_HOST'!\033[0m"
    echo "Рекомендуется добавить её, чтобы компоненты системы могли разрешать это имя."

    echo -e "\n\033[1;36m[Инструкция для Windows (вы работаете в WSL)]\033[0m"
    echo "Браузер запущен в Windows, поэтому запись нужно добавить в Windows-файл hosts."
    echo "1. Откройте PowerShell от имени Администратора и выполните:"
    echo -e "\033[1;32m   Add-Content C:\Windows\System32\drivers\etc\hosts \"127.0.0.1  $TARGET_HOST\"\033[0m"
    echo "2. Сбросьте кэш DNS в Windows:"
    echo -e "\033[1;32m   ipconfig /flushdns\033[0m"

    echo -e "\n\033[1;36m[Инструкция для Linux]\033[0m"
    echo "Выполните команду в терминале (потребуется пароль sudo, если вы работает в wsl добавить запись так же необходимо и для windows):"
    echo -e "\033[1;32m   echo \"127.0.0.1  $TARGET_HOST\" | sudo tee -a $HOSTS_FILE\033[0m"

    # Всегда выводим подсказку по правильному пробросу SSH-туннеля
    echo -e "\033[1;36m💡 Подсказка для SSH-туннеля:\033[0m"
    echo "Для доступа к веб-интерфейсу через имя хоста запустите туннель командой:"
    echo -e "\033[1;32m   $TUNNEL_CMD\033[0m\n"

    echo "Запуск контейнеров..."
    docker compose -f docker-compose.yml up -d
    docker exec lr-jenkins-jenkins-master-1 cat /var/jenkins_home/.ssh/id_ed25519.pub | docker exec -i lr-jenkins-jenkins-agent1-1 sh -c 'mkdir -p /home/jenkins/.ssh && chmod 700 /home/jenkins/.ssh && cat > /home/jenkins/.ssh/authorized_keys && chmod 600 /home/jenkins/.ssh/authorized_keys && chown -R jenkins:jenkins /home/jenkins/.ssh'
    docker exec lr-jenkins-jenkins-master-1 cat /var/jenkins_home/.ssh/id_ed25519.pub | docker exec -i lr-jenkins-jenkins-agent2-1 sh -c 'mkdir -p /home/jenkins/.ssh && chmod 700 /home/jenkins/.ssh && cat > /home/jenkins/.ssh/authorized_keys && chmod 600 /home/jenkins/.ssh/authorized_keys && chown -R jenkins:jenkins /home/jenkins/.ssh'
}

get_ssh_private_key() {
    # Имя контейнера мастера Jenkins
    local CONTAINER_NAME="lr-jenkins-jenkins-master-1"

    # Путь к приватному ключу внутри контейнера
    local KEY_PATH="/var/jenkins_home/.ssh/id_ed25519"

    # Проверяем, запущен ли контейнер
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "❌ Ошибка: Контейнер ${CONTAINER_NAME} не запущен или не существует." >&2
        return 1
    fi

    echo "📋 Скопируйте приватный ключ ниже (включая BEGIN и END строки) и вставьте в Jenkins UI:"
    echo "--------------------------------------------------------------------------------"

    # Читаем ключ от имени пользователя jenkins
    docker exec -u jenkins "$CONTAINER_NAME" cat "$KEY_PATH"

    echo "--------------------------------------------------------------------------------"
}

# Функция для остановки контейнеров
stop() {
    if [ "$1" = "-v" ]; then
        echo "Остановка и удаление контейнеров (включая volumes)..."
        docker compose -f docker-compose.yml down -v --timeout 0
    else
        echo "Остановка и удаление контейнеров..."
        docker compose -f docker-compose.yml stop --timeout 0
    fi
}

test() {
    docker compose exec -it jenkins-test bash --rcfile /venv/bin/activate
}

# Обработка переданного аргумента
case "$1" in
    build)
        build
        ;;
    start)
        start
        ;;
    doc)
        doc "${@:2}"
        ;;
    stop)
        stop "${@:2}"
        ;;
    gp)
        getpasswd
        ;;
    gpk)
        get_ssh_private_key
        ;;
    test)
        test
        ;;
    *)
        echo "Использование: $0 {build|start|doc|stop}"
        exit 1
        ;;
esac
