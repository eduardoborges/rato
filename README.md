# MouseHIDpp

App de menu bar para macOS que ajusta DPI, polling e luz de um mouse Logitech e mostra a bateria. Fala HID++ direto com o mouse pelo IOHIDManager, sem o G HUB. O G HUB precisa estar fechado, porque os dois disputam o mesmo pipe HID.

## Testado em

| Peça | Valor |
|---|---|
| Receptor | LIGHTSPEED `0x046d:0xc539`, mouse no slot 1 |
| Bateria | feature `0x1001` (tensão) |
| LED | feature `0x8071` (RGB por cluster) |
| Ajustes | DPI `0x2201`, polling `0x8060`, perfis onboard `0x8100` |

O código também lê `0x1000` (bateria em %), mas essa via nunca rodou num mouse de verdade. Os ajustes do menu precisam do `0x8100`.

## Requisitos

- macOS 13 ou mais novo
- Swift 5.9+ (Xcode ou Command Line Tools)
- G HUB fechado

## Uso

```bash
cd app
swift run
```

Para não depender do `swift run`, compile em release e rode o binário:

```bash
swift build -c release
.build/release/MouseHIDpp
```

No menu, cada mouse tem os submenus DPI, Polling e Luz. As mudanças vão para o perfil ativo na memória do mouse, como o G HUB faz, e continuam valendo com o app fechado e depois do sleep. Antes de cada gravação o app salva os setores do mouse em `~/Library/Application Support/MouseHIDpp/backups/`.

Os mesmos ajustes existem na linha de comando:

```bash
swift run MouseHIDpp state                         # DPI, polling, modo e efeitos de LED
swift run MouseHIDpp profiles                      # os 5 perfis gravados no mouse
swift run MouseHIDpp set dpi 400,800,1600,3200 4   # níveis de DPI e qual deles é o padrão
swift run MouseHIDpp set dpi-default 2
swift run MouseHIDpp set rate 1                    # polling em ms: 1, 2, 4 ou 8
swift run MouseHIDpp set led off                   # ou: color ff0000, breathe 00ff00, cycle
swift run MouseHIDpp backup
swift run MouseHIDpp restore <pasta do backup>
```

Para gravar, o G HUB precisa estar fechado. O app recusa enquanto o `lghub_agent` estiver rodando.

## Ícones da barra

| Ícone | Significado |
|---|---|
| mouse preenchido até o nível + `≈98%` | nível lido; o `≈` indica que veio da tensão |
| mouse com raio | carregando |
| mouse vazio + `1400mV` | só a tensão, sem estimativa (pilha AA) |
| mouse apagado | procurando ou nenhum mouse respondeu |

O item "Mostrar porcentagem" do menu liga e desliga o número ao lado do ícone, e a escolha fica salva entre execuções.

## Problemas comuns

| Sintoma | O que fazer |
|---|---|
| Ícone apagado | Mexa o mouse para acordá-lo e clique em "Re-escanear". Se não resolver, feche o G HUB. O `probe` mostra o que o receptor respondeu |
| Menu mostra "Não gravou" | Mexa o mouse para acordá-lo e tente de novo. Se a gravação falhar no meio, o app regrava o original; `restore` volta qualquer backup |
| `probe` não acha nenhum device | O receptor não está na USB ou outro processo segura o pipe |

## Limitações

- Os botões ainda não são configuráveis.
- O LED usa o mesmo efeito nas duas zonas do G703.
- No menu, as cores são uma paleta fixa e ciclo e respiração usam 8 s e 4 s com intensidade 100%. Outra cor só pela linha de comando.
- A porcentagem no `0x1001` é uma reta entre 3400 e 4120 mV, não a curva do G HUB.
- Um mouse por receptor: o primeiro slot que responde.
- O app não abre sozinho no login.

## Como funciona

Framing HID++, descoberta de features, bateria e a receita do LED estão em [RELATORIO.md](RELATORIO.md).

## Layout

- `app/`: o executável Swift
- `RELATORIO.md`: o protocolo, passo a passo
- `analysis/lghub_agent.arm64`: slice arm64 do `lghub_agent`, de onde saiu o protocolo

O binário fica fora do git (`.gitignore`). Tem 105 MB e é da Logitech, então não dá para redistribuir. Para recriar com o G HUB instalado:

```bash
mkdir -p analysis
lipo -thin arm64 \
  /Applications/lghub.app/Contents/MacOS/lghub_agent.app/Contents/MacOS/lghub_agent \
  -output analysis/lghub_agent.arm64
shasum -a 256 analysis/lghub_agent.arm64
# 830c86d14865bfd263e11582af756c919985e10fb87542d3acf9e11f4d2151f8 (a versão analisada)
```
