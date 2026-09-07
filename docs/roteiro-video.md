# Roteiro do vídeo — máximo 20 minutos

> **Regra de avaliação (literal):** *"Qualquer requisito que não for claramente
> demonstrado no vídeo ou documentado no relatório **sofrerá dedução direta de
> pontos**. Não basta configurar; é preciso mostrar operando na prática."*
>
> Cada bloco abaixo aponta o **requisito** que ele cobre. Nada aqui é enfeite.

**Divisão:** Pitch Executivo **9 min** · Demo Tech **10 min** · Fechamento **1 min**

---

## Antes de gravar — checklist

- [ ] `make lab-up` executado, ambiente estável há **≥ 30 min**
- [ ] `make carga` rodando há ≥ 20 min — **sem tráfego os painéis de SLO ficam vazios**
- [ ] Dashboards SRE e FinOps com dados
- [ ] Uma execução do `self-heal.yml` já no histórico do Actions
- [ ] Um backup do Velero concluído (`velero backup get`)
- [ ] Abas abertas na ordem: Grafana(SRE) · Grafana(FinOps) · ArgoCD · Actions · New Relic · Tag Editor · terminal
- [ ] Cronômetro visível

> O erro mais comum é gravar com o ambiente recém-subido. Os painéis ficam vazios,
> o Prometheus ainda não tem janela de 5 min e o vídeo "prova" que nada funciona.

---

# PARTE 1 — Pitch Executivo (9 min)

> **Público: a diretoria da ONG.** Sem jargão. A pergunta que eles têm é
> *"isto é viável e é seguro?"*, não *"qual a versão do Kubernetes?"*.

### 1.1 O problema (1 min)

> "A SolidaryTech ganhou a rede nacional e o acesso explodiu. A diretoria fez
> três perguntas: se a nuvem cair, as doações param? Quanto isso custa por mês?
> E quanto tempo levamos para descobrir que quebrou? Nós respondemos as três com
> número — e é isso que vou mostrar."

### 1.2 Arquitetura (2 min) — `docs/02-arquitetura/README.md`

> Material de apoio para esta parte e para o fechamento:
> [`evolucao-v3-v4-v5.md`](02-arquitetura/evolucao-v3-v4-v5.md) — o que foi
> herdado, o que foi corrigido e o que é novo, com evidência em arquivo.

Mostrar o diagrama macro. Falar de **negócio**, não de YAML:

- Três serviços, com o de **doações** tratado como caminho crítico.
- **A decisão que protege o dinheiro:** a doação é gravada e confirmada ao doador
  **antes** de notificar voluntários. Se o serviço de voluntários cair, o evento
  **fica na fila** — nenhuma doação se perde.
- Tudo provisionado por código: **nada foi clicado no console**.

### 1.3 Confiabilidade — SLO e SLA (2 min) — **F1** · `docs/03-sre/sli-slo-sla.md`

Abrir o **Dashboard SRE**. Apontar para o gauge de error budget:

> "Prometemos 99,9% de disponibilidade. Isto aqui mostra quanto do nosso
> 'orçamento de falha' ainda resta. Quando cai abaixo de 20%, **congelamos
> deploys automaticamente**. Não é um relatório mensal — é um freio."

- **SLA de 99,5%** às ONGs, mais frouxo que o SLO de propósito: a folga de ~3,2 h
  é o que absorve um incidente ruim sem quebrar contrato.
- Compensação: crédito de serviço proporcional.

### 1.4 Custo — FinOps (2 min) — **F2** · `docs/04-finops/README.md`

Abrir o **Dashboard FinOps**.

> "**US$ 202 por mês.** Sabemos quanto custa cada serviço, não só o total."

Mostrar duas decisões com número:
- Um banco em vez de dois → **US$ 12,90/mês**
- NAT Gateway desligado → **US$ 32,40/mês**, com o risco declarado e revertível
  por uma variável.

Recomendação de maior impacto: **desligar o ambiente fora de uso** — de 2 semanas
para mais de 2 meses de crédito. É processo, não configuração.

### 1.5 Continuidade — PCN (2 min) — **F4.1** · `docs/06-dr-pcn/pcn.md`

> "Se a região da Virgínia cair inteira: **1 hora** para voltar, com no máximo
> **15 minutos** de doações perdidas. E o backup fica em **outra região** — na
> mesma região não protegeria contra o cenário que ele existe para cobrir."

Mencionar que os **débitos são declarados**: sem Multi-AZ, sem TLS, sem WAF —
limitações do ambiente da faculdade, com o desenho correto documentado ao lado.
**Isso conta a favor, não contra.**

---

# PARTE 2 — Demo Tech (10 min)

> Os cinco itens que o enunciado lista, na ordem dele.

### 2.1 Pipeline CI/CD e deploy via ArgoCD (2 min) — **F0.3, F0.4**

**GitHub → Actions**, abrir uma execução do `ci-donation`:
- `lint` ‖ `test` em paralelo → `sast` + `build-scan-push` → `update-gitops`
- Abrir o passo do **Trivy**: as duas camadas (dependências e imagem)
- Abrir o commit gerado pelo `update-gitops` — **é a ponte CI→CD**

**ArgoCD** (`http://<NLB>/argocd/`):
- Todas as Applications `Synced` / `Healthy`
- Abrir `app-donation` e mostrar a tag da imagem = SHA do commit

> "Nenhum `kubectl apply` de aplicação. O deploy nasce de um commit."

### 2.2 Terraform e tags FinOps (2 min) — **F0.2, F2.1**

Terminal:
```bash
make check                # gate do AWS Academy: 20 arquivos, 0 falhas
make conformidade         # relatório de conformidade com o lab
```

**Console AWS → Resource Groups & Tag Editor**, filtrar `CostCenter = NGO-Core`:

> "Todos os recursos, **incluindo as instâncias EC2** — que não herdariam tag
> automaticamente. Foi preciso um launch template próprio para isso, e é onde a
> maior parte da fatura está."

### 2.3 APM, traces e alertas (2 min) — **F0.5b, F3.1**

**New Relic → Distributed Tracing**, abrir um trace de doação:

> "Um trace só, atravessando três serviços **e uma fila SQS**. O `traceparent`
> viaja como atributo da mensagem — sem isso, seriam dois traces desconexos."

- Copiar o `trace_id` → **Grafana → Loki** → mesma requisição, linha exata de log
- **New Relic → Alerts & AI → Anomalies**: a anomalia detectada pela IA
- **Prometheus → Alerts**: as regras de burn rate configuradas

### 2.4 Dashboard SRE com SLOs calculados (2 min) — **F1.2**

**Grafana → SRE**:
- Três gauges de error budget com **números reais**
- Burn rate com as faixas 1× / 6× / 14,4×
- p95 e p99 com a linha do SLO em 300 ms

> "Estes números são calculados a partir de um histograma que a aplicação emite.
> Na Fase 4 tínhamos só um contador de requisições — e por isso o SLO de latência
> era 'proposto', nunca medido. É a principal correção desta entrega."

### 2.5 Backup e DR em ação (2 min) — **F4.2**

**Opção A — Velero:**
```bash
velero backup get
kubectl delete namespace solidary-volunteer          # apagar de propósito
velero restore create --from-backup <mais-recente> --include-namespaces solidary-volunteer
kubectl -n solidary-volunteer get pods               # de volta
```

**Opção B — Warm standby:**
```bash
make dr-plan     # plan limpo em us-west-2, os MESMOS módulos
```

> "O ambiente de DR não redefine nada: chama os mesmos módulos com outra região.
> É isso que prova a modularização — um DR duplicado divergiria da produção na
> primeira mudança, e é assim que planos de DR morrem."

---

# Fechamento (1 min)

> "Três serviços em EKS, provisionados 100% por Terraform, entregues por GitOps,
> com SLO calculado, custo conhecido por serviço, incidente mitigado
> automaticamente e recuperação testada em outra região. Tudo dentro das
> restrições do AWS Academy — sem criar uma única IAM role, porque o ambiente não
> permite, e cada contorno está documentado com o desenho correto ao lado."

---

## Mapa requisito → minuto

| Req. | O quê | Bloco | ~min |
|---|---|---|---|
| F0.1 | Docker e Kubernetes | 2.1 | 10 |
| F0.2 | Terraform | 2.2 | 12 |
| F0.3 | CI/CD DevSecOps | 2.1 | 10 |
| F0.4 | GitOps | 2.1 | 11 |
| F0.5 | Observabilidade e APM | 2.3 | 14 |
| F1.1 | SLIs e SLOs | 1.3 / 2.4 | 4 / 16 |
| F1.2 | Dashboard SRE | 2.4 | 16 |
| F1.3 | MTTR | 1.3 + relatório | 4 |
| F2.1 | Tags | 2.2 | 13 |
| F2.2 | Rightsizing | 1.4 | 6 |
| F2.3 | Forecast | 1.4 | 6 |
| F3.1 | AIOps | 2.3 | 15 |
| F3.2 | Ciclo de incidente | relatório | — |
| F4.1 | PCN | 1.5 | 8 |
| F4.2 | DR prático | 2.5 | 18 |
