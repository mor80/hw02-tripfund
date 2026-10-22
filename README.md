# TripFund

ДЗ №2, базовый вариант и все три бонусных задания: ERC-20 сбор на поездку,
Transparent Proxy и обновление V1 → V2 с оплатой за другого участника.

## Установка и проверка

Версии: Solidity **0.8.28**, Foundry **1.7.1**, Node.js **22+**,
OpenZeppelin Contracts / Contracts Upgradeable **5.0.2**,
OpenZeppelin Upgrades Core **1.44.2**, forge-std **1.9.7**.
forge-std включён в `lib/`; остальные зависимости закреплены в `package-lock.json`.

Установить [Foundry](https://getfoundry.sh/introduction/installation/), затем:

```sh
foundryup --install v1.7.1
git clone https://github.com/mor80/hw02-tripfund.git
cd hw02-tripfund
npm ci
forge build
forge test -vv
npm run validate:upgrade
```

`npm run check` запускает форматирование, тесты и проверку обновления.
Тесты работают локально: RPC, кошелёк и тестовый ETH не нужны.

## Контракты

- `src/TripFund.sol` — V1: `initialize`, `contribute`, `withdraw`, `refund`.
- `src/TripFundV2.sol` — V2: наследует V1 и добавляет `contributeFor`.
- `src/MockToken.sol` — обычный OpenZeppelin ERC-20, 18 decimals, без комиссии
  и rebasing; начальная эмиссия передаётся конструктору.

V1 сразу создаётся через `TransparentUpgradeableProxy` OpenZeppelin 5.x.
`initialize(token, organizer, goal, deadline)` передаётся в конструктор прокси.
`goal` и суммы задаются в минимальных единицах токена, `deadline` — Unix-время
в секундах. Изменять параметры после инициализации нельзя.
Реализации блокируют прямую инициализацию, прокси — повторную.

Взносы принимаются строго до дедлайна, выплаты — начиная с дедлайна.
При `totalRaised >= goal` организатор однократно получает всю учтённую сумму;
иначе вкладчики независимо возвращают свои вклады.
`totalRaised` сохраняет историческую сумму и после выплат не уменьшается.
Прямые переводы токенов не учитываются и остаются на прокси после выплат.
Используются SafeERC20, обновление учёта до внешних вызовов и защита от reentrancy.

## Пример approve и взноса

Вызовы делает плательщик; `proxy` — адрес прокси, `token` — адрес ERC-20:

```solidity
IERC20(token).approve(proxy, 10 ether);
TripFund(proxy).contribute(10 ether);

IERC20(token).approve(proxy, 5 ether);
TripFundV2(proxy).contributeFor(friend, 5 ether);
```

Для `contributeFor` токены списываются у плательщика, а вклад и право возврата
получает `friend`. При провале `friend` вызывает `TripFundV2(proxy).refund()`.
Примеры развёртывания и обновления — в `test/Upgrade.t.sol`.
Обновление выполняет только владелец созданного прокси контракта `ProxyAdmin`
через `upgradeAndCall(proxy, newImplementation, "")`.

## Тесты и совместимость хранилища

101 тест, включая fuzz-проверки по 256 запусков:

- `test/TripFund.t.sol` — все основные требования для V1 и V2: взносы,
  ошибки и откат учёта, границы дедлайна, оба исхода, повторные выплаты,
  балансы и неучтённые прямые переводы.
- `test/Transfers.t.sol` — возврат `false` и revert токена, восстановление
  учёта после ошибки, порядок обновления состояния и запрет reentrancy.
- `test/Upgrade.t.sol` — взнос в V1, обновление до дедлайна с сохранением
  адреса, параметров, вкладов, суммы и баланса, оплата за друга, возврат другу,
  обычный взнос после обновления, запрет чужого обновления и инициализации.

`npm run validate:upgrade` пересобирает build-info и запускает официальный
[OpenZeppelin Upgrades CLI](https://docs.openzeppelin.com/upgrades-plugins/api-core)
для V1 и V2. Для V2 обязателен reference V1: проверяются безопасность реализации
и совместимость storage layout. Пропуск проверок не используется.
