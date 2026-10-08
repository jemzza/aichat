# План

Агент выполняет шаги по одному, после каждого — сборка, отметка `[x]`, коммит.
Время — ориентир; реалистично ~9–10 ч на обязательную часть.
Шаги с пометкой **👤** требуют действия пользователя — агент останавливается и просит.

## 0. Каркас (~1 ч)

- [ ] 0.1 `project.yml` (`developmentLanguage: en`, GRDB через `exactVersion`,
      `UIApplicationSupportsMultipleScenes: false`, `Assets.xcassets` с
      `AppIcon`/`AccentColor`, `Localizable.xcstrings`), `Build.command`
      (режим `NO_PAUSE=1` без ожидания клавиши), пустое приложение
      `AIChatApp` с экраном-заглушкой.
      Проверить: `NO_PAUSE=1 ./Build.command` собирает и запускает в симуляторе.
      **👤** Установить рантайм симулятора iOS 18 (Xcode → Settings → Components).
- [ ] 0.2 Папки слоёв (`App/`, `Features/`, `Domain/`, `Data/`), `AppContainer`.
      Под XCTest контейнер не поднимает реальную БД/монитор сети/миграцию старта.
- [ ] 0.3 Ключ: заглушка `Secrets` (ключа нет → `unauthorized`), тест на
      деобфускацию на синтетических данных (не на реальном ключе).
      Проверка: `git grep -n "gsk_"` пуст.
      **👤** Пользователь сам запускает `GROQ_API_KEY=… python3 scripts/gen_secrets.py`.
- [ ] 0.4 `ai-logs/`: README с правилом — после каждого раздела экспортировать
      транскрипт, вычистить ключи, email, пути с именем пользователя.

## 1. Данные (~1 ч)

- [ ] 1.1 Доменные модели `Chat`, `Message`, `MessageStatus` (два автомата),
      `ErrorKind` (включая `forbidden`) — по `docs/task.md`.
- [ ] 1.2 GRDB: `AppDatabase`, миграция v1 (FK с `ON DELETE CASCADE`),
      записи для `Chat`/`Message`, сортировка `createdAt, rowid`.
- [ ] 1.3 `ChatRepository` (протокол в Domain, реализация в Data):
      создать/удалить/переименовать чат, добавить/обновить сообщение,
      атомарный `claimPending` (`pending` → `sent` + ответ `streaming`),
      `observeChats()`, `observeMessages(chatId:)` как `AsyncStream`.
- [ ] 1.4 Тесты репозитория на in-memory базе (включая каскадное удаление и
      повторный `claimPending` → ничего не делает).
- [ ] 1.5 При старте: `streaming` → `interrupted` + тест.

## 2. AI-клиент (~1 ч 30 мин)

- [ ] 2.0 **👤 + агент:** выбрать модель Groq, записать в `docs/task.md` модель
      и лимиты RPM/TPD; проверить доступность API из страны проверяющего.
- [ ] 2.1 Протокол `LLMProvider` → `AsyncThrowingStream<String, Error>`;
      протокол `ConnectivityProviding`.
- [ ] 2.2 `SSEParser` построчный (`data:`, `[DONE]`, мусор, ошибка в `data:`) + тесты.
- [ ] 2.3 `GroqProvider`: запрос `stream: true`, контекст по правилам из
      `docs/task.md`, разбор дельт, отмена через `Task` cancellation.
- [ ] 2.4 Маппинг ошибок в `ErrorKind` по таблице из `docs/task.md`
      (отмена ≠ offline, ошибка в SSE при 200, 403) + тесты.

## 3. Логика чата (~2 ч)

- [ ] 3.1 `ConnectivityMonitor` на `NWPathMonitor` + фейк для тестов/DEBUG.
- [ ] 3.2 `ChatService`: отправка, живой черновик в памяти, троттлинг записи
      в БД (инжектируемый `Clock`), стоп, повтор, outbox (сеть / запуск /
      foreground), отмена при удалении чата, `beginBackgroundTask`.
- [ ] 3.3 Тесты `ChatService` с фейковыми провайдером и сетью на in-memory БД:
      троттлинг, «Стоп» → `cancelled` с частичным текстом, ошибка → `failed`
      + `errorKind`, outbox без двойной отправки, повтор.
- [ ] 3.4 Автозаголовок чата обрезкой первого сообщения.
- [ ] 3.5 DEBUG launch-аргументы `-mockOffline`, `-mockError <code>`,
      `-mockSlowStream` в `AppContainer`.

## 4. UI (~3 ч)

Критерий готовности каждого шага — скриншоты из симулятора: светлая и тёмная
тема; для 4.2–4.6 — ещё iOS 18 и iOS 26.

- [ ] 4.1 `ChatListView` + `ChatListViewModel`: список, новый чат, удаление
      свайпом, пустое состояние. `NavigationSplitView`.
- [ ] 4.2 `ChatView` + `ChatViewModel`: пузыри, автоскролл (в т.ч. во время
      стриминга), клавиатура, поле ввода, кнопка «Send» ↔ «Stop».
- [ ] 4.3 Состояния сообщения: «печатает…» до первого токена, ошибка с текстом
      по `ErrorKind` и «Retry», «Stopped», «Will send when online».
- [ ] 4.4 Пустой экран чата с 3–4 подсказками-запросами.
- [ ] 4.5 Баннер «No connection». Инлайн-markdown в ответах.
- [ ] 4.6 Проверка Dynamic Type (уровень AX) и Liquid Glass на iOS 26 vs iOS 18.

## 5. Проверка и сдача (~2 ч)

- [ ] 5.1 Прогон на симуляторах iOS 18 и iOS 26: сценарии из README.
- [ ] 5.2 Сценарии ошибок через DEBUG-аргументы: без сети → `pending` →
      отправка, «Stop», `xcrun simctl terminate` во время стриминга →
      `interrupted`, 429/401/403/500.
- [ ] 5.3 README по шаблону, честный раздел «Не сделано».
- [ ] 5.4 Финальная чистка `ai-logs/`, `git grep` на ключи/email,
      проверка распаковкой архива в новую папку и двойным кликом по Build.command.

## 6. Бонусы (по остатку времени, скорее всего не влезут)

- [ ] 6.1 `FoundationModelsProvider` (iOS 26) + кнопка «Answer offline».
      Сначала проверить: доступность модели на симуляторе и поддержку языка.
- [ ] 6.2 Mac Catalyst в `project.yml`.
- [ ] 6.3 Фото во вложении (`PhotosPicker`, мультимодальная модель).
- [ ] 6.4 Русская локализация в `Localizable.xcstrings`.

## Журнал отклонений от плана

_Сюда записываем, что пошло не так и что решили иначе._

- Ревью плана до старта: добавлены живой черновик стриминга (исключение из
  offline-first), раздельные автоматы статусов, правило офлайн-ответа,
  маппинг ошибок, DEBUG-хуки, тесты `ChatService`, шаг выбора модели,
  `ai-logs` с первого шага; оценки пересчитаны (~6,5 ч → ~9–10 ч).
- Базовый язык интерфейса — английский (решение заказчика); русский — бонус 6.4.
