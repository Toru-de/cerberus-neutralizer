# Cerberus Neutralizer

Мод для Cyberpunk 2077 **2.5** и Phantom Liberty. В задании **Somewhat Damaged («Взгляд в бездну»)** он отключает зрение и слух патрульного Cerberus, чтобы можно было заниматься терминалами и головоломками. Подходит для установки перед загрузкой существующего сохранения внутри Cynosure.

## Установка на облачный ПК

1. Закройте игру. Установите **Cyber Engine Tweaks 1.38.1** в папку игры. Поддержка патча 2.5 появилась в CET 1.38.0. [Скачать CET 1.38.1](https://github.com/maximegmd/CyberEngineTweaks/releases/tag/v1.38.1)
2. Распакуйте `CerberusNeutralizer-v0.2.0.zip` в корень `Cyberpunk 2077`, объединив папки `bin`. При обновлении подтвердите замену `init.lua`. Итоговый путь должен быть `Cyberpunk 2077/bin/x64/plugins/cyber_engine_tweaks/mods/CerberusNeutralizer/init.lua`. [Скачать ZIP](https://github.com/Toru-de/cerberus-neutralizer/releases/download/v0.2.0/CerberusNeutralizer-v0.2.0.zip)
3. Запустите игру и загрузите свой сейв. Индикатор появится вверху экрана, когда мод найдёт Cerberus. Чтобы проверить отключение сенсоров, откройте оверлей CET и найдите статус **Cerberus patrol sensors suppressed**.

На облачном ПК нужен доступ к файлам игры и возможность запуска CET. Единственная зависимость мода — CET. [Руководство по установке CET](https://wiki.redmodding.org/cyber-engine-tweaks/getting-started/installing)

## Настройки в оверлее CET

| Настройка | Действие |
| --- | --- |
| **Enable Cerberus Neutralizer** | Включает мод. По умолчанию включено. |
| **Disable Cerberus Detection** | Отключает сенсоры патруля, сбрасывает накопленное обнаружение Ви и отфильтровывает шаги, бег, приземления и другие сенсорные стимулы Ви для этого робота. По умолчанию включено. |
| **Disable Cerberus Attacks** | Отключает запуск действия `CerberusBoss.CerberusAttacks` в режиме патруля. По умолчанию выключено. Уже начатый захват и удары, запускаемые сценой или триггером задания, обрабатывает игра. |
| **Show Cerberus HUD** | Показывает индикатор вверху экрана при закрытом меню CET. По умолчанию включено. |
| **Debug Mode** | Показывает ID найденной сущности, профиль восприятия, показание обнаружения, режим сцены Ви и число отфильтрованных стимулов. Переходы и ошибки записываются в журнал мода `CerberusNeutralizer.log` рядом с `init.lua`. |

Настройки сохраняются в `settings.json` в папке мода. Если при перезагрузке модов из оверлея окно ждёт Cerberus, загрузите свой сейв ещё раз, чтобы мод получил событие появления робота.

## Индикатор Cerberus

- **CERBERUS** показывает расстояние по прямой до робота, пока его сущность загружена.
- **MOVING AWAY** появляется, когда сам робот удаляется от Ви.
- **SIGNAL LOST** показывает, сколько секунд прошло с момента потери сигнала после обнаружения робота.
- **RETURNED** на несколько секунд отмечает возвращение сигнала.

Секунды после потери сигнала отсчитываются вверх. Показания описывают положение и доступность сущности, поэтому проходимость маршрута оценивайте по обстановке. Индикатор скрывается в кат-сценах и при известных профилях сюжетной погони.

## Сюжетные сцены и удаление мода

Мод проверяет активность `q305_bunker` и точную запись `Character.q305_cerberus_robot`. В кат-сценах и при профилях сюжетной погони управление возвращается игре. Во время игрового управления, включая работу с терминалами, защита действует и при профиле `Senses.Default`. При неизвестном профиле сенсоры работают по правилам игры. Мод ограничивает изменения сенсорами и боевым действием Cerberus. Получение компонента Cerberus, чертежа Militech Canto Mk.6 и создание кибердеки остаются частью обычного прохождения.

Если захват уже начался, загрузите ближайшее сохранение до захвата. На постановочных отрезках следуйте текущей цели, включая побег к шлюзу. Чтобы вернуть стандартное поведение, снимите галочку **Enable Cerberus Neutralizer** и закройте оверлей. Для удаления закройте игру и удалите папку `CerberusNeutralizer` из каталога `mods`.

## Проверка

Синтаксис, фильтрация шагов и смена состояний проверены локально на LuaJIT с имитацией CET. Тест индикатора покрывает движение Ви, отход робота, потерю и возвращение сигнала, а также отрисовку при закрытом оверлее. Внутриигровая проверка индикатора, бега в Cynosure, постановочных погонь и финала ещё нужна.

```text
lua tests/smoke.lua
```

- Совместимость CET с игрой и Lua-интерфейсы. [CET 1.38.0](https://github.com/maximegmd/CyberEngineTweaks/releases/tag/v1.38.0), [события CET](https://wiki.redmodding.org/scripting-cyberpunk/cyber-engine-tweaks/cet-functions/events), [реализация TweakDB в CET 1.38.1](https://github.com/maximegmd/CyberEngineTweaks/blob/v1.38.1/src/reverse/TweakDB/TweakDB.cpp).
- Сигнатуры методов и переключение сенсоров. [Декомпиляция скриптов игры 2.5](https://codeberg.org/adamsmasher/cyberpunk/src/commit/17c62d000310f8938beb9593b3892c6c4febeffb), [RTTI компонента `senseComponent`](https://github.com/wopss/RED4ext.NativeDB/blob/master/src/assets/natives/classes/senseComponent.json).
- Запись робота, журнал и параметры TweakDB. [Экспорт записей NPC](https://open2077.net/docs/npc-catalogue), [список путей журнала](https://github.com/CDPR-Modding-Documentation/Cyberpunk-Modding-Docs/blob/main/for-mod-creators-theory/references-lists-and-overviews/reference-quest-ids.md), [индекс имён TweakDB из WolvenKit](https://github.com/WolvenKit/WolvenKit/blob/95074158ed971aea39fc8abc50c2574381f4aad2/WolvenKit.Common/Resources/tweakdbstr.kark).
