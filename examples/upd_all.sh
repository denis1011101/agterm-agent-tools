#!/bin/bash
# upd_all.sh — Resilient Linux & AI agent toolkit updater with network recovery

# Таймаут действует на dpkg-блокировку (upgrade/dist-upgrade), но не на
# /var/lib/apt/lists/lock у apt-get update (Debian #1069167) — её ждём сами.
APT_OPTS=(-o DPkg::Lock::Timeout=300)

SUDO_REFRESH_PID=
NETWORK_RESTARTING=0
RESTORE_UUID=
RESTORE_DEV=
RESTORE_NAME=
RESTORE_TYPE=

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [[ -n $SUDO_REFRESH_PID ]]; then
        kill "$SUDO_REFRESH_PID" 2>/dev/null || true
        wait "$SUDO_REFRESH_PID" 2>/dev/null || true
    fi
    if (( NETWORK_RESTARTING )) && [[ -n $RESTORE_UUID ]]; then
        local -a ifname_arg=()
        [[ -n "$RESTORE_DEV" ]] && ifname_arg=(ifname "$RESTORE_DEV")
        timeout 35s nmcli --wait 30 connection up uuid "$RESTORE_UUID" "${ifname_arg[@]}" 2>/dev/null || true
    fi
    exit "$status"
}

# --- Проверка интернет-подключения и автоперезапуск сетевого соединения ---

# Базовая проверка доступности: пинг 8.8.8.8, резолв/пинг google.com с таймаутом,
# либо HTTPS fallback (на случай фильтрации ICMP).
ping_check() {
    ping -4 -n -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 \
        || timeout 4s ping -4 -c 1 -W 2 google.com >/dev/null 2>&1 \
        || curl -4 -fsS --connect-timeout 2 --max-time 4 https://www.google.com/generate_204 -o /dev/null 2>&1
}

# Подтверждённая проверка: защита от единичного случайного дропа пакета на Wi-Fi.
# Если пинг сорвался, делается немедленный повтор через 0.5 с.
check_internet() {
    ping_check || { sleep 0.5 && ping_check; }
}

# Фаза 1: Ожидание появления первой связности (до timeout секунд)
wait_for_initial_connection() {
    local timeout="$1"
    local deadline=$((SECONDS + timeout))
    local last_log=0

    while (( SECONDS < deadline )); do
        if check_internet; then
            return 0
        fi
        local remaining=$((deadline - SECONDS))
        if (( SECONDS - last_log >= 5 )); then
            echo "==> Ожидаю появления интернета... (осталось до ${remaining} с)"
            last_log=$SECONDS
        fi
        sleep 1
    done
    return 1
}

# Фаза 2: Проверка стабильности в течение 30 секунд.
# Каждые 3 секунды пингуем сеть. Если происходит обрыв (например, через 10 секунд
# после старта системы из-за реконфигурации VPN) — немедленно фиксируем сбой.
# На отметке >= 30 с выполняется обязательная контрольная проверка.
verify_stability() {
    local window="$1"
    local interval=3
    local start_time=$SECONDS
    local elapsed=0
    local last_log=-1

    while true; do
        elapsed=$((SECONDS - start_time))
        if (( elapsed >= window )); then
            if ! check_internet; then
                echo "==> Связь оборвалась на финальной ${elapsed}-й секунде!"
                return 1
            fi
            echo "==> Проверяю стабильность: ${window}/${window} с (успешно)"
            return 0
        fi

        if (( elapsed - last_log >= 3 )); then
            echo "==> Проверяю стабильность: ${elapsed}/${window} с..."
            last_log=$elapsed
        fi

        if ! check_internet; then
            echo "==> Связь оборвалась на ${elapsed}-й секунде!"
            return 1
        fi

        local remaining=$((window - elapsed))
        local sleep_time=$interval
        (( remaining < sleep_time )) && sleep_time=$remaining
        sleep "$sleep_time"
    done
}

# Полный цикл: дождаться ответа + выдержать 30 секунд непрерывной стабильности
test_network_cycle() {
    if ! wait_for_initial_connection 30; then
        echo "==> Интернета нет (таймаут ожидания 30 с)"
        return 1
    fi
    verify_stability 30
}

find_active_physical_connection() {
    TARGET_UUID=""
    TARGET_NAME=""
    TARGET_DEV=""
    TARGET_TYPE=""

    if ! command -v nmcli >/dev/null 2>&1; then
        return 1
    fi

    local d t s u n count selected_idx min_metric best_idx rline rdev rmetric i j
    local -a dev_arr=() type_arr=() uuid_arr=() name_arr=() words=()

    while IFS=: read -r d t s u n; do
        [[ -z "$d" ]] && continue
        if [[ "$s" == "connected" && -n "$u" ]]; then
            if [[ "$t" == "ethernet" || "$t" == "wifi" ]]; then
                dev_arr+=("$d")
                type_arr+=("$t")
                uuid_arr+=("$u")
                name_arr+=("$n")
            fi
        fi
    done < <(nmcli -g DEVICE,TYPE,STATE,CON-UUID,CONNECTION device 2>/dev/null)

    count=${#dev_arr[@]}
    if (( count == 0 )); then
        return 1
    fi

    selected_idx=-1

    if (( count == 1 )); then
        selected_idx=0
    else
        # Несколько физических устройств: выбираем default route с наименьшей метрикой из main
        min_metric=999999999
        best_idx=-1

        while IFS= read -r rline; do
            [[ "$rline" != default* ]] && continue
            rdev=""
            rmetric=0
            words=($rline)
            for (( i=0; i<${#words[@]}; i++ )); do
                if [[ "${words[i]}" == "dev" && $((i+1)) -lt ${#words[@]} ]]; then
                    rdev="${words[i+1]}"
                elif [[ "${words[i]}" == "metric" && $((i+1)) -lt ${#words[@]} ]]; then
                    rmetric="${words[i+1]}"
                fi
            done

            for (( j=0; j<count; j++ )); do
                if [[ "${dev_arr[j]}" == "$rdev" ]]; then
                    if (( rmetric < min_metric )); then
                        min_metric=$rmetric
                        best_idx=$j
                    fi
                fi
            done
        done < <(ip -4 route show table main default 2>/dev/null)

        if (( best_idx >= 0 )); then
            selected_idx=$best_idx
        else
            # Если маршрут по умолчанию отсутствует: отдаём приоритет ethernet перед Wi-Fi
            for (( j=0; j<count; j++ )); do
                if [[ "${type_arr[j]}" == "ethernet" ]]; then
                    selected_idx=$j
                    break
                fi
            done
            if (( selected_idx < 0 )); then
                selected_idx=0
            fi
        fi
    fi

    TARGET_UUID="${uuid_arr[selected_idx]}"
    TARGET_NAME="${name_arr[selected_idx]}"
    TARGET_DEV="${dev_arr[selected_idx]}"
    TARGET_TYPE="${type_arr[selected_idx]}"
    return 0
}

restart_active_connection() {
    local attempt="$1"
    local max="$2"

    # Если уже есть незавершённое восстановление (например, предыдущая попытка сорвалась на up),
    # не переключаемся на другой профиль (Wi-Fi) и не делаем новый down, а продолжаем поднимать сохранённый профиль.
    if (( NETWORK_RESTARTING )) && [[ -n "$RESTORE_UUID" ]]; then
        echo "==> Повторная попытка активации ранее отключённого подключения '${RESTORE_NAME}' ($RESTORE_DEV, попытка $attempt из $max)..."
        local -a ifname_arg=()
        [[ -n "$RESTORE_DEV" ]] && ifname_arg=(ifname "$RESTORE_DEV")

        if timeout 35s nmcli --wait 30 connection up uuid "$RESTORE_UUID" "${ifname_arg[@]}" >/dev/null 2>&1; then
            NETWORK_RESTARTING=0
            echo "==> Подключение '${RESTORE_NAME}' ($RESTORE_DEV) успешно активировано."
            return 0
        else
            echo "==> Предупреждение: повторная активация '${RESTORE_NAME}' ($RESTORE_DEV) не удалась."
            return 1
        fi
    fi

    if ! find_active_physical_connection; then
        echo "==> Не удалось определить активное физическое подключение (Ethernet/Wi-Fi) в NetworkManager для перезапуска."
        return 1
    fi

    echo "==> Перезапуск подключения '${TARGET_NAME}' ($TARGET_DEV, $TARGET_TYPE, попытка $attempt из $max)..."

    # Сохраняем параметры до отключения; общий EXIT/INT/TERM trap повторит up при прерывании
    RESTORE_UUID="$TARGET_UUID"
    RESTORE_NAME="$TARGET_NAME"
    RESTORE_DEV="$TARGET_DEV"
    RESTORE_TYPE="$TARGET_TYPE"
    NETWORK_RESTARTING=1

    local -a ifname_arg=()
    [[ -n "$TARGET_DEV" ]] && ifname_arg=(ifname "$TARGET_DEV")

    # Шаг 1: Деактивация профиля
    timeout 15s nmcli --wait 10 connection down uuid "$TARGET_UUID" >/dev/null 2>&1 || true

    sleep 2

    # Шаг 2: Активация профиля (обязательно даже при ошибке на шаге down)
    if timeout 35s nmcli --wait 30 connection up uuid "$TARGET_UUID" "${ifname_arg[@]}" >/dev/null 2>&1; then
        NETWORK_RESTARTING=0
        echo "==> Подключение '${TARGET_NAME}' ($TARGET_DEV) успешно перезапущено."
        return 0
    else
        echo "==> Предупреждение: не удалось активировать подключение '${TARGET_NAME}' ($TARGET_DEV)."
        return 1
    fi
}

ensure_network() {
    local max_restarts=2

    echo "==> Проверка подключения к интернету и стабильности канала (30 с)..."
    if test_network_cycle; then
        echo "==> Соединение стабильно в течение 30 с; запускаю обновление."
        return 0
    fi

    local attempt
    for (( attempt=1; attempt<=max_restarts; attempt++ )); do
        if restart_active_connection "$attempt" "$max_restarts"; then
            echo "==> Сетевое подключение перезапущено. Повторная проверка стабильности..."
            if test_network_cycle; then
                echo "==> Соединение стабильно в течение 30 с; запускаю обновление."
                return 0
            fi
        else
            echo "==> Попытка перезапуска сети не удалась."
        fi
    done

    echo "==> Ошибка: не удалось добиться стабильного подключения к интернету после $max_restarts попыток перезапуска."
    return 1
}

apt_update() {
    local deadline=$((SECONDS + 300)) log
    log=$(mktemp)
    while true; do
        sudo env LC_ALL=C.UTF-8 apt-get "${APT_OPTS[@]}" -o APT::Update::Error-Mode=any update 2>&1 | tee "$log"
        if (( PIPESTATUS[0] == 0 )); then rm -f "$log"; return 0; fi
        if ! grep -q 'Could not get lock .*lists/lock' "$log" || (( SECONDS >= deadline )); then rm -f "$log"; return 1; fi
        echo "==> apt занят другим процессом, повтор через 10 с..."
        sleep 10
    done
}

update_agterm() {
    local repo=melonamin/agterm-linux installed latest tag deb sums dir
    installed=$(dpkg-query -W -f '${Version}' agterm-linux 2>/dev/null) || { echo "==> agterm-linux не установлен, пропускаю"; return 0; }
    tag=$(curl -fsS --max-time 30 -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/$repo/releases/latest" | jq -r '.tag_name // empty') \
        || { echo "==> agterm: не удалось запросить GitHub API (лимит или сеть), пропускаю"; return 1; }
    latest=${tag#linux-v}
    [[ -n $latest ]] || { echo "==> agterm: не удалось определить последний релиз, пропускаю"; return 1; }
    if ! dpkg --compare-versions "${installed%-*}" lt "$latest"; then
        echo "==> agterm-linux: установлена актуальная версия $installed (последний релиз $latest)"
        return 0
    fi
    echo "==> agterm-linux: установлена старая версия $installed, доступна $latest — обновляю"
    deb="agterm-linux-v$latest-x86_64.deb"
    sums="agterm-linux-v$latest-SHA256SUMS"
    dir=$(mktemp -d)
    chmod 755 "$dir"
    (
        cd "$dir" \
        && curl -fSL --max-time 600 -o "$deb" "https://github.com/$repo/releases/download/$tag/$deb" \
        && curl -fsSL --max-time 30 -o "$sums" "https://github.com/$repo/releases/download/$tag/$sums" \
        && grep " $deb\$" "$sums" | sha256sum -c - \
        && sudo apt-get "${APT_OPTS[@]}" install -y "./$deb"
    ) || { rm -rf "$dir"; echo "==> Обновление agterm-linux не удалось"; return 1; }
    rm -rf "$dir"
    echo "==> agterm-linux: $(dpkg-query -W -f '${Version}' agterm-linux)"
}

# If sourced as a library (e.g. by unit/integration tests), return early without running main
if (return 0 2>/dev/null); then
    return 0
fi

# Main execution:
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Сначала запрашиваем пароль, пока пользователь ещё у терминала.
echo "==> Запрос sudo..."
sudo -v || exit 1

# -n запрещает фоновый запрос пароля; -v обновляет timestamp явно.
(
    refresh_sleep_pid=
    trap 'if [[ -n $refresh_sleep_pid ]]; then
              kill "$refresh_sleep_pid" 2>/dev/null || true
              wait "$refresh_sleep_pid" 2>/dev/null || true
          fi
          exit 0' INT TERM
    while kill -0 "$$" 2>/dev/null; do
        sudo -n -v || exit 1
        sleep 50 &
        refresh_sleep_pid=$!
        wait "$refresh_sleep_pid"
        refresh_sleep_pid=
    done
) 2>/dev/null &
SUDO_REFRESH_PID=$!

if ! ensure_network; then
    exit 1
fi

failed=0
if apt_update; then
    sudo apt-get "${APT_OPTS[@]}" upgrade -y \
        && sudo apt-get "${APT_OPTS[@]}" dist-upgrade -y \
        && sudo apt-get "${APT_OPTS[@]}" autoremove -y \
        || failed=1
else
    failed=1
fi
(( failed )) && echo "==> Обновление системных пакетов не удалось, продолжаю с CLI-инструментами"

# OpenCode
if command -v opencode >/dev/null 2>&1; then
    echo "==> Обновление OpenCode (текущая: $(opencode --version 2>/dev/null))"
    opencode upgrade --method curl || { echo "==> Обновление OpenCode не удалось"; failed=1; }
    echo "==> OpenCode: $(opencode --version 2>/dev/null)"
else
    echo "==> opencode не найден в PATH, пропускаю"
fi

# Antigravity CLI (agy)
if command -v agy >/dev/null 2>&1; then
    echo "==> Обновление agy (текущая: $(agy --version 2>/dev/null))"
    agy update || { echo "==> Обновление agy не удалось"; failed=1; }
    echo "==> agy: $(agy --version 2>/dev/null)"
else
    echo "==> agy не найден в PATH, пропускаю"
fi

# Codex CLI
if command -v codex >/dev/null 2>&1; then
    echo "==> Обновление Codex (текущая: $(codex --version 2>/dev/null))"
    codex update || { echo "==> Обновление Codex не удалось"; failed=1; }
    echo "==> Codex: $(codex --version 2>/dev/null)"
else
    echo "==> codex не найден в PATH, пропускаю"
fi

# agterm-linux
update_agterm || failed=1

exit $failed
