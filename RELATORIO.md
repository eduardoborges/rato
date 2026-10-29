# Engenharia reversa — Logitech G HUB para HID++ no macOS

App menu bar que ajusta DPI, polling e LED de um mouse Logitech e mostra a bateria, falando HID++ direto pelo IOHIDManager. Não usa o G HUB em runtime.

Medido em 17/10/2026 neste Mac: receptor LIGHTSPEED `0x046d:0xc539`, mouse no slot 1. Bateria `0x1001` em ≈98% (4107 mV). `MouseHIDpp off` aceito pelo feature `0x8071` e o LED apagou.

## Alvo

`lghub_agent`, o backend do G HUB. Mach-O universal; o slice analisado foi o arm64.

- SHA-256: `830c86d14865bfd263e11582af756c919985e10fb87542d3acf9e11f4d2151f8`
- Cópia: `analysis/lghub_agent.arm64`
- Image base no Ghidra: `0x100000000`

A UI é Electron (`lghub_ui.app`). O renderer fala com o agent por WebSocket `ws://localhost:9010`. Rotas que importam para este trabalho: `/battery/state/changed` e `/lighting/turn_off_for_inactivity`. O app Swift não usa esse canal. O protocolo de verdade está no agent, nas classes `devio::Feature<id>…`, que montam o report USB.

## Como o G HUB chega no mouse

O agent abre o device com `devio::MacOSDevice` (`IOHIDDevice`). O HID++ não sai pela interface de teclado nem de mouse (usage page `0x01`). Sai pela collection vendor, `PrimaryUsagePage = 0xFF00`, reports de 32 bytes. No `0xC539` as interfaces de boot devolvem `kIOReturnNotPermitted` se o processo tenta abri-las; a vendor abre.

`devIdx` `0xFF` é conexão direta (USB ou Bluetooth) ou o próprio receptor. No LIGHTSPEED o mouse pareado está num slot `1…6`. Nesta máquina é o slot 1. Tratar `0xFF` como o mouse faz o handshake cair no receptor, que não tem bateria nem LED.

## Framing no macOS

HID++ curto, 7 bytes no fio:

```
10  devIdx  featureIdx  (func<<4)  p0  p1  p2
```

HID++ longo, 20 bytes:

```
11  devIdx  featureIdx  (func<<4)  p0 … p15
```

`IOHIDDeviceSetReport` pede o report id no argumento e no byte 0 do buffer. Se o buffer começa no device index, o IOHID grava `0x10` por cima desse byte. O índice real escorrega uma posição e o receptor responde erro `0x8F`, com `resp[1] == req[2]`. O modo que funciona é id no argumento e no byte 0.

Descoberta de feature (root, índice 0, função 0):

```
params: featureId_hi, featureId_lo
resp:   index, version
```

Índice `0x00` na resposta significa que o device não tem aquela feature.

## Bateria

Dois features, o primeiro que existir.

`0x1000` BATTERY_LEVEL_STATUS, função 0, sem payload. Resposta de 3 bytes: `level` (0–100; `0xFF` = desconhecido), `nextLevel`, `status`. Status visto no G HUB: 0 descarregando, 1 carregando, 2 quase cheia, 3 cheia, 4 erro de carga.

`0x1001` BATTERY_VOLTAGE, função 0, sem payload. Resposta: tensão em mV, big-endian 16 bits, mais um byte de flags. Bit 7 = carregando. Bits 0–2 = código de falha. O mouse desta máquina só expõe `0x1001`. O G HUB tira a porcentagem de uma curva de descarga por modelo de mouse (abaixo). Sem ela, o app usa uma reta de Li-ion entre 3400 mV e 4120 mV. O app marca `≈` nos dois casos.

### Modelo de consumo (battery.xml)

O G HUB baixa para cada mouse um `battery.xml`, em `/Library/Application Support/Logi/LGHUB/depots/<id>/<mouse>/`. No agent, quem lê o arquivo é o `battery_model_voltage` (`get_voltage_discharge_map`, `get_voltage_soc_map`).

- A raiz `<powermodel vid pid>` traz o PID sem fio do mouse; o do G703 é `0x4086`. O app pega os PIDs pela feature `0x0003`, função 0: o modelId fica nos bytes 7 a 12 da resposta, um PID de 2 bytes por transporte. O G703 responde `0x4086` e `0xc090`.
- `<discharge>`: linhas `minutos,tensão em V,mWh gastos`. No G703 são 707 pontos, de 4,186 V a 3,479 V, com 904 mWh no total.
- `<blocks>`: consumo em mW. `sensor` e `mcu` são fixos, `report_rate` tem um valor por intervalo e `lighting` tem um valor por zona, efeito (`off`, `solid`, `cycling`, `breathing`) e brilho. O `mcu_load` entra quando algum LED está aceso.
- `<charging>` e `<charging_time_slots>` vêm vazios no G703.

Horas restantes = (total − mWh gastos na tensão lida) ÷ soma dos blocos. O agent tira a média de várias leituras de tensão (`average_voltage_sample_count`); o app usa uma leitura só. Para cor fixa, o app usa o canal mais forte como brilho, e o G HUB pode calcular de outro jeito.

O arquivo não é XML válido: tem `--` dentro de um comentário, e o `XMLDocument` recusa. O app tira os comentários antes do parse.

## LED

O G HUB escolhe a via pelo feature que o device anuncia.

| Feature | Classe devio | Papel |
|---|---|---|
| `0x8070` | `Feature8070ColorLEDEffects` | RGB por zona |
| `0x8071` | `Feature8071RGBEffects` | RGB por cluster (G502, G703, G Pro…) |
| `0x1300` | `Feature1300LEDControl` | LED mono |

`turn_off_lighting` no agent (`0x101ea6140`) percorre as zonas e aplica o efeito None (`Effect_Id = 1`). A tabela `Effect_Id → raw 0x8070` em `0x102bb51b4` é `{0x00, 0x01, 0x03, 0x04, 0x0A, 0x0B}` para os ids 1…6.

No `0x8071` o primeiro byte do payload é GET (`0x00`) ou SET (`0x01`) nas funções que têm os dois. `SetEffectByIndex` é a função 1, 13 bytes, flags no fim — não no começo:

```
cluster, effectRaw, R, G, B, 0x02, 0,0,0,0,0,0, flags
```

`effectRaw` 0 = none, 1 = cor fixa. Apagar com none só pega em efeito fresco. Cor fixa preta aplica sempre.

Receita que apagou o LED neste `0xC539` (feature `0x8071` no índice `0x07`, versão 0):

1. Função 5, SET SW-control: `01 01 00`
2. Função 1, cor fixa preta, em cada cluster que responde (aqui 0, 1 e 2; o 3 não existe): payload de 13 bytes acima com RGB `00 00 00` e flags `01`

O readback depois do write confirmou o framing: `GetInfo` devolveu `ff 00 02 00 0b 00 04` (2 clusters, 11 no campo do meio, 4 no seguinte), e `GetSWControl` ecoou o controle de software ligado (`p[1] = 01`).

`0x8070` apaga com função 3, `[zoneIdx, 0x00]`, depois de tomar SW-control na função 8 com `[0x01, 0x00]`. `0x1300` apaga com função 5, 9 bytes: `[idx, 0x00, 0x80, intensidade_hi, intensidade_lo, 0, 0, 0, 0]`, intensidade 0.

Restaurar, no `0x8071`, é a mesma função 1 com RGB `ff ff ff`, e soltar o SW-control com função 5 `01 00 00`.

## Perfis onboard (0x8100)

O G703 expõe estas features públicas: `0x1001` bateria, `0x8071` LED, `0x8100` perfis onboard, `0x8110` captura de botões, `0x8060` polling, `0x2201` DPI, `0x1d4b` status sem fio e `0x0020` config change. As do tipo `0x60` (`0x18xx`, `0x1exx`) são internas.

O G HUB deixa o G703 em modo onboard (`0x8100` f2 devolve 1) e grava as configurações no perfil. O teste que decidiu o desenho do app:

| Modo | DPI ao vivo (`0x2201` f3) | Polling ao vivo (`0x8060` f2) | Ao voltar para onboard |
|---|---|---|---|
| onboard | aceita | erro 2 (argumento inválido) | o perfil recarrega e descarta o DPI ao vivo |
| host (`0x8100` f1 `[2]`) | aceita | aceita | perfil 0, botão de DPI do perfil inativo |

Índices de função do `0x8100`, conferidos no libratbag: f0 descrição, f1/f2 modo, f3/f4 perfil atual (`[0, n]`), f5 leitura, f6 início de escrita, f7 dados, f8 fim, f11/f12 índice de DPI atual.

A descrição (f0) traz 5 perfis, 6 botões e setores de 255 bytes. O diretório fica no setor `0x0000`, com 4 bytes por perfil (`endereço BE16, ativo, reservado`) e `FFFF` no fim. Os perfis do usuário ficam em `0x0001` a `0x0005`; os de fábrica, em `0x0101` em diante. Todo setor termina em CRC-16/CCITT (início `0xFFFF`, polinômio `0x1021`) dos primeiros 253 bytes, big endian.

| Offset | Campo |
|---|---|
| 0 | polling em ms |
| 1 | índice do DPI padrão |
| 2 | índice do DPI shift |
| 3 a 12 | 5 níveis de DPI, little endian, 0 = vazio |
| 32 a 95 | 16 botões, 4 bytes cada |
| 208 e 219 | 2 LEDs, 11 bytes cada: ID do efeito e 10 bytes de parâmetros |

Os parâmetros do LED seguem o mesmo layout do `0x8071`: fixo com cor em 1 a 3; respiração com cor em 1 a 3, período BE16 em 4 e 5, forma de onda em 6 e intensidade em 7; ciclo com período BE16 em 6 e 7 e intensidade em 8. O perfil grava o ID do efeito (`0x00`, `0x01`, `0x03`, `0x0a`); o comando ao vivo do `0x8071` usa o índice do efeito na lista do cluster, que se lê com f0 `[cluster, efeito, 0]`.

Leitura: f5 com `[setor BE16, offset BE16]` devolve 16 bytes; o último bloco começa no offset 239. Escrita: f6 `[setor BE16, 0, 0, tamanho BE16]`, f7 com blocos de 16 bytes (o último com padding), f8. Depois disso, f3 `[0, n]` recarrega o perfil, o que aplica polling e LED. O nível de DPI em uso continua o mesmo até f12 `[índice]`.

O app faz backup dos 6 setores, confere todos os CRCs, grava só o setor do perfil ativo, relê byte a byte e regrava o original se não bater. Os testes deixaram o mouse idêntico ao primeiro backup.

Duas armadilhas do cliente HID++: erros do HID++ 2.0 chegam como `[dev, 0xFF, feature, função, código]` e não seguem o eco normal, então precisam de tratamento próprio; e o filtro que descarta o eco do próprio pedido só vale para respostas do GET_REPORT, porque respostas legítimas cheias de zero (f8, blocos vazios) chegam por input report.

## O que não foi fechado

A persistência do LED não precisa do `SetNvConfig` (`0x8071` função 3). Gravar o efeito no perfil onboard resolve, como descrito em "Perfis onboard".

A curva mV→% do G HUB para devices que só têm `0x1001` ficou de fora. Em 3920 mV a reta deu ≈72% e o G HUB mostrou 71%.

Os botões (16 entradas de 4 bytes no perfil, mais o `0x8110`) ainda não foram mapeados.

## ATK e VXE (Compx)

Fonte: ATK HUB Beta 3.2.6 (`cn.atk.drive`), um app Electron. O `app.asar` de fora só abre a janela. A interface e o protocolo ficam em `Contents/Resources/main/app.asar`, no `static/index-*.js` (15 MB, minificado). O que importa está na classe do mouse Compx (a que o código testa com `isCompxMouse`), na base dos pacotes de 16 bytes e no transporte, que manda tudo pelo report 8.

O receptor `0x373B:0x11FE` ("Wireless mouse 8k NANO dongle-L") tem três interfaces: mouse, teclado e uma vendor com usage page `0xFF05`. A vendor declara os reports `0x10`, `0x02`, `0x05`, `0x03`, `0x08` (16 bytes, entrada e saída), `0x06` (feature de 7 bytes), `0x09` (48 bytes) e `0x0B` (mouse). O filtro WebHID do ATK HUB pede a collection `0xFF04` uso 2. No macOS o IOHIDDevice é a interface inteira, então o Rato reconhece o aparelho pela collection `0xFF02`, a que carrega o report 8.

O pacote é igual nos dois sentidos:

```
cmd  status  addr_hi  addr_lo  len  d0 … d9  checksum
```

O checksum é `0x55 − (8 + soma dos bytes 0 a 14)`, módulo 256. A resposta repete o comando no byte 0, e as da EEPROM repetem também o endereço.

| Cmd | Nome no ATK HUB | O que faz |
|---|---|---|
| `0x03` | GetWirelessMouseOnline | d0 = 1 quando o mouse está ligado ao receptor |
| `0x04` | GetBatteryLevel | d0 = %, d1 = 1 carregando, d2 e d3 = mV big endian |
| `0x07` | SetEEPROM | grava `len` bytes em `addr` |
| `0x08` | GetEEPROM | devolve `len` bytes de `addr` a partir de d0 |
| `0x10` | GetMouseCIDMID | d0 = cid, d1 = mid; o par identifica o modelo |

Na EEPROM, todo campo vem seguido de um byte de conferência, `0x55 − soma do campo`.

| Endereço | Conteúdo |
|---|---|
| `0x0000` | polling, quantos níveis de DPI, nível em uso (base 0) e bhop |
| `0x000C` | 8 níveis de DPI de 4 bytes: x, y, extra e conferência |
| `0x002C` | cor de cada nível |
| `0x004C` | luz do DPI: efeito (1 fixo, 2 respiração), brilho (16, 128 ou 255), velocidade (1, 3 ou 5) e ligada |
| `0x0060` | botões |
| `0x1B00` | níveis do PAW3955, 6 bytes cada: x e y em 16 bits, extra e conferência |

Códigos de polling: `1` = 1000 Hz, `2` = 500, `4` = 250, `8` = 125, `16` = 2000, `32` = 4000 e `64` = 8000.

A conta do DPI muda com o sensor, e o sensor sai do par cid/mid na tabela de aparelhos do ATK HUB, copiada em `CompxModels.swift`. No PAW3395 e no PAW3950, o valor é 50 × (1 + n), com n de 10 bits: os 2 bits altos ficam no byte extra, e o bit `0x01` dobra o valor. No PAW3950 Ultra, sem o bit `0x02` o valor é 10 × (n + 1), e com ele, 50 × n + 10050. O PAW3955 guarda o valor menos 1 em 16 bits. O PAW3395SE e o PAW3311 usam uma tabela de valores, o PAW3320 divide por 39 e 38, e o Rato ainda não converte nenhum dos três.

Testado num ATK A9 Ultra Max 2.0 (cid 1, mid 37, PAW3950 Ultra) no receptor 8K, em 29/10/2026:

- O framing é o do HID++: id no argumento e no byte 0 do buffer. A resposta chega como input report 8 de 17 bytes, com o id no byte 0. Sem o id no buffer, o receptor não responde.
- A resposta usa o mesmo checksum do pedido.
- O mouse dorme uns 20 s depois de parar. Dormindo, o receptor responde ao `0x03` com d0 = 0 e não responde à bateria nem ao cid/mid. Só o movimento acorda o mouse: com ele parado, ler a EEPROM não acordou. Numa outra vez a EEPROM respondeu enquanto a bateria e o cid/mid não respondiam, e a causa não ficou clara.
- A gravação vale na hora. Com o polling em 1000 Hz chegaram 1030 reports por segundo, e em 4000 Hz, 3940.
- O ATK HUB tinha gravado 1 nível e o nível em uso 0, então o índice começa em 0. Os bytes gravados batem com a conta do 3950 Ultra: `4a 4a 44` é 3310 e `3f 3f 44` é 3200.

## G HUB que não abre

Se o G HUB trava em "Loading applications", confira se existe `/Library/LaunchDaemons/com.logi.ghub.updater.plist`. O `lghub_updater` roda como daemon (`--daemonized`) e serve HTTP local; sem ele, o `lghub_agent` fica esperando em `resources_helper::get_local_http_url` para cada modelo de device e a UI nunca termina de carregar. O `lghub_installer --silent` não repara, porque responde "Already installed!" enquanto `/Applications/lghub.app` existe. O que resolveu foi recriar o plist com `ProgramArguments` = `[lghub_updater, --daemonized]`, `RunAtLoad` e `KeepAlive`, e ativar com `launchctl bootstrap system`.

## App

`app/` é um executável Swift (`Rato`). Sem argumentos, sobe na menu bar com a bateria e os submenus DPI, Polling e Luz, que gravam no perfil ativo. Na linha de comando, `state`, `profiles` e `features` só leem; `set`, `backup` e `restore` gravam.

O G HUB precisa estar fechado. Os dois processos disputam o mesmo pipe, e o app recusa gravar com o `lghub_agent` rodando.
