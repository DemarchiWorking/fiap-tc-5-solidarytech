# Post-Mortem — <título curto do incidente>

> **Blameless.** A pergunta não é *"quem errou?"* — é *"que propriedade do
> sistema permitiu que esse erro chegasse à produção?"*. Post-mortem que procura
> culpado produz relatório defensivo, e relatório defensivo esconde a causa raiz.
>
> Obrigatório em todo alerta `severity: page`, em até **48 h** — inclusive quando
> o self-heal resolveu sozinho. A mitigação automática cria justamente o risco de
> o incidente virar crônico sem ninguém investigar.

| Campo | Valor |
|---|---|
| **Data** | AAAA-MM-DD |
| **Duração** | Xh Ymin (detecção → resolução) |
| **Severidade** | P1 / P2 |
| **Serviços afetados** | |
| **Incident Commander** | |
| **Autor** | |

---

## 1. Impacto

- **Usuários afetados:** (nº de doações com erro, ONGs impactadas)
- **Impacto financeiro:** (valor em doações não processadas)
- **Error budget consumido:** X% do orçamento de disponibilidade
- **SLA violado?** sim / não

---

## 2. Linha do tempo

Horários em UTC. Registrar o que foi **observado**, não o que se concluiu depois.

| Horário | Evento | Fonte |
|---|---|---|
| 00:00 | Causa raiz introduzida (deploy, mudança de configuração, pico) | |
| 00:00 | Primeiro sintoma observável | métrica |
| 00:00 | **Alerta disparou** | Alertmanager |
| 00:00 | Self-heal acionado | GitHub Actions |
| 00:00 | Humano reconheceu | PagerDuty |
| 00:00 | Causa raiz identificada | |
| 00:00 | Mitigação aplicada | |
| 00:00 | **Serviço restaurado** | |

**MTTD** (detecção): ___ min · **MTTR** (recuperação): ___ min

---

## 3. Causa raiz — 5 porquês

1. **Por que** o serviço falhou? →
2. **Por que** isso aconteceu? →
3. **Por que** isso aconteceu? →
4. **Por que** isso aconteceu? →
5. **Por que** isso aconteceu? →

> Parar no primeiro "porquê" produz ação corretiva rasa ("reiniciar o pod").
> Chegar ao quinto costuma revelar um problema de **processo**, não de código.

---

## 4. O que funcionou

- (detecção automática, self-heal, runbook útil, trace resolvendo em minutos)

## 5. O que não funcionou

- (alerta atrasado, runbook desatualizado, falta de dashboard, escalonamento lento)

## 6. Onde tivemos sorte

- (o que poderia ter sido muito pior e não foi — por acaso, não por desenho)

> Esta seção costuma ser a mais valiosa. "Sorte" é um controle que ainda não
> existe.

---

## 7. Ações corretivas

**Toda ação tem dono e prazo.** Ação sem dono é intenção.

| # | Ação | Tipo | Dono | Prazo | Status |
|---|---|---|---|---|---|
| 1 | | prevenir / detectar / mitigar | | | |
| 2 | | | | | |

**Tipos:** *prevenir* (impede a recorrência) · *detectar* (pega mais cedo na
próxima vez) · *mitigar* (reduz o impacto quando ocorrer).

Um post-mortem só com ações de *mitigar* indica que a causa raiz não foi
realmente encontrada.

---

## 8. Pergunta obrigatória

> **Que alerta teria detectado isso antes de o doador ser afetado?**

Se a resposta for "nenhum", **criar esse alerta é a ação corretiva nº 1**.

---

## 9. Comunicação realizada

| Público | Quando | Canal | Conteúdo |
|---|---|---|---|
| ONGs parceiras | | | |
| Diretoria | | | |
