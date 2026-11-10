#!/bin/bash
set -euo pipefail

NETWORK_RESTARTING=0
RESTORE_UUID=""
RESTORE_NAME=""
RESTORE_DEV=""
RESTORE_TYPE=""

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
