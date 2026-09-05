# Enunciado — Tech Challenge Fase 5 (Hackathon) · FIAP PosTech DevOps & Arquitetura Cloud

> Transcrição estruturada do enunciado oficial. O texto bruto, sem edição, está em
> [`enunciado-original.txt`](enunciado-original.txt). Onde houver divergência, **o original prevalece**.

---

## 0. Enquadramento

| Item | Valor |
|---|---|
| Natureza | **Hackathon** — projeto que engloba os conhecimentos de **todas as fases** |
| Duração | **2 meses corridos** |
| Formato | **Em grupo** |
| Peso | **90% da nota de todas as disciplinas da Fase 5** — atividade obrigatória |
| Janela de entrega | 22/07/2026 a **29/09/2026** |
| Tipo | **Projeto novo** (não é continuação do produto das fases anteriores) |
| Código-fonte fornecido | <https://github.com/dougls/hackathon-DCLT> |

> **Objetivo declarado:** *"O objetivo não é apenas entregar código, mas provar a maturidade
> operacional, financeira e de resiliência de um ambiente em nuvem utilizando as práticas de
> SRE, FinOps, Segurança e ITSM/AIOps."*

---

## 1. O desafio

Construir, orquestrar, monitorar, otimizar financeiramente e criar a estratégia de resiliência
para o novo ecossistema de microsserviços da **SolidaryTech**.

| Microsserviço | Responsabilidade |
|---|---|
| `ngo-service` | Cadastro e gestão de ONGs parceiras |
| `donation-service` | Processamento das doações — **Caminho Crítico / Hot Path** |
| `volunteer-service` | Match entre voluntários e campanhas |

### 1.1 Regra de Ouro (projeto evolutivo)

> *"Para que este cenário seja realista e válido para avaliação, é **obrigatório** que toda a base
> tecnológica aprendida nas Fases 1, 2, 3 e 4 seja aplicada a este novo ecossistema. **Não haverá
> deploy manual via kubectl, não haverá infraestrutura 'clicada' no console e não haverá voo cego
> sem monitoramento profundo.**"*

---

## 2. Contexto de negócio

A SolidaryTech é uma iniciativa **sem fins lucrativos** que conecta ONGs a doadores e voluntários
em todo o Brasil. A plataforma ganhou destaque em rede nacional, o que gerou **picos de acesso
imprevisíveis**. A diretoria exige garantias empresariais rígidas:

- Se a nuvem cair (**Disaster Recovery**), as doações **não podem parar**.
- Os custos de infraestrutura (**FinOps**) estão fora de controle e precisam ser **tagueados e justificados**.
- O tempo de resposta a incidentes precisa ser **preditivo (AIOps)**, não apenas reativo.
- São necessários **acordos de nível de serviço (SLO/SLA) claros** com as ONGs parceiras.

---

## 3. Requisitos técnicos — as 5 frentes de avaliação

### Frente 0 — A Fundação DevOps (Fases 1 a 4) · **Requisito Obrigatório**

Antes de aplicar as práticas da Fase 5, o projeto deve **comprovar a utilização de todas as
disciplinas anteriores**:

| # | Requisito | Detalhe textual do enunciado |
|---|---|---|
| F0.1 | **Docker e Kubernetes** | Dockerfiles **otimizados** para os 3 novos serviços e implantação em Kubernetes (**EKS, AKS ou GKE**) |
| F0.2 | **Infraestrutura como Código** | Provisionamento de **todo** o ambiente (Cluster, Bancos de Dados, Mensageria, Rede) via **Terraform** |
| F0.3 | **CI/CD e DevSecOps** | Pipelines automatizados (ex.: GitHub Actions) com **testes**, **scans de segurança (SAST/SCA — Trivy/Sonar)** e **construção da imagem** |
| F0.4 | **GitOps** | Entrega contínua via **ArgoCD ou FluxCD** |
| F0.5 | **Observabilidade e APM** | Stack completa rodando (**Prometheus, Grafana, Loki e/ou OpenTelemetry**) **e** instrumentação no APM (**Datadog ou New Relic**) com **Distributed Tracing** |

### Frente 1 — SRE: Confiabilidade e Golden Metrics

> *"A engenharia de confiabilidade deve ser a prioridade."*

| # | Requisito | Critério textual |
|---|---|---|
| F1.1 | **Definição de SLOs e SLIs** | Para o **`donation-service`**, definir e documentar **no mínimo 2 SLIs** baseados nas **Golden Metrics** (ex.: Latência e Taxa de Erros). Estabelecer o **SLO** de cada um (ex.: 99.9% de sucesso) |
| F1.2 | **Dashboard SRE** | Painel **específico** no Grafana ou no APM, focado **exclusivamente** nos SLOs e no **consumo do Error Budget** |
| F1.3 | **MTTR** | Evidenciar **no relatório** como a stack de observabilidade e as automações de resposta a incidentes reduzem **ativamente** o MTTR |

### Frente 2 — FinOps: Otimização Financeira e Tagueamento

> *"Como o orçamento da ONG é limitado, cada centavo conta."*

| # | Requisito | Critério textual |
|---|---|---|
| F2.1 | **Estratégia de Tagging (IaC)** | Política de tags rigorosa **diretamente no código Terraform**. **Todos** os recursos devem conter as tags obrigatórias `Project=SolidaryTech`, `Environment=Production`, `CostCenter=NGO-Core` |
| F2.2 | **Rightsizing** | Analisar métricas de **CPU/Memória** do Kubernetes e ajustar **`requests` e `limits`** dos Pods nos manifestos YAML **via GitOps** |
| F2.3 | **Relatório de Forecast** | Projeção de **custos mensais** da arquitetura + **ao menos 1 recomendação prática** de otimização nativa de nuvem |

### Frente 3 — ITSM e AIOps: Gestão Preditiva

> *"Incidentes devem ser previstos antes de afetarem o doador."*

| # | Requisito | Critério textual |
|---|---|---|
| F3.1 | **Configuração de AIOps** | Ativar as funcionalidades de **IA da ferramenta de APM** (ex.: **Watchdog** no Datadog, **Applied Intelligence** no New Relic) para **detecção automática de anomalias comportamentais** |
| F3.2 | **Gestão de Incidentes (ITSM)** | Desenhar o **fluxo de vida de um incidente** — da **detecção via AIOps/alerta** até o **Post-Mortem** e a **comunicação aos stakeholders** |

### Frente 4 — Multicloud, Segurança e Disaster Recovery

> *"Se o cluster principal cair, a SolidaryTech precisa sobreviver."*

| # | Requisito | Critério textual |
|---|---|---|
| F4.1 | **Plano de Continuidade de Negócios (PCN)** | Documento **executivo**. Definir os valores críticos de **RTO** e **RPO** para os **dados das doações** |
| F4.2 | **Estratégia de DR Prática** | Implementar **e evidenciar** backup/DR — **Opção A**: **Velero** fazendo backup do estado do cluster (manifestos e volumes) para **bucket externo**; **Opção B**: Terraform modularizado capaz de levantar um ambiente **espelho (Warm Standby)** em **outra região com 1 comando** |

---

## 4. Entregáveis

> ⚠️ **REGRA DE AVALIAÇÃO (literal):** *"É obrigatório evidenciar o funcionamento de todas as
> métricas, configurações e requisitos solicitados abaixo. **Qualquer requisito que não for
> claramente demonstrado no vídeo ou documentado no relatório sofrerá dedução direta de pontos.**
> Não basta configurar; é preciso mostrar operando na prática."*

### E1 — Código-fonte no repositório
- Código **IaC completo (Terraform)** com **tags FinOps**.
- **Manifestos YAML** configurados com **`limits`/`requests`** (Rightsizing).
- **Arquivos de pipeline** (GitHub Actions / GitLab CI) contemplando **DevSecOps**.

### E2 — Vídeo de demonstração (**até 20 min**)
- **Pitch Executivo (15 a 20 min):** apresentar **arquitetura**, **PCN** e **estratégias
  financeiras** *"como se estivesse vendendo a viabilidade do projeto para a diretoria da ONG"*.
- **Demo Tech (Fundação + Hackathon):**
  1. Pipelines **CI/CD rodando** e o **deploy no cluster via ArgoCD**;
  2. **Terraform rodando** (ou evidência da criação de recursos **baseada em tags**);
  3. **Rastreabilidade no APM (Traces)** e os **alertas configurados**;
  4. **Dashboard SRE** com as **Golden Metrics** e os **SLOs calculados**;
  5. **Sistema de Backup/DR em ação** (Velero, ou módulos Terraform prontos para a região secundária).

### E3 — Relatório de entrega (**.PDF**)
- **Nomes, RMs e usernames**.
- **Links** do repositório de código e do vídeo.
- **Evidências visuais (obrigatório):**
  - **Seção SRE:** definição **formal** de **SLI, SLO e SLA** do serviço de doações.
  - **Seção FinOps:** análise de **custos mensais (Forecast)** e **evidências das tags aplicadas**.
  - **Seção Segurança e DR:** documento de **PCN (com RPO e RTO)** e explicação da estratégia de DR.
  - **Seção ITSM/AIOps:** **desenho do ciclo de vida de incidentes**.

---

## 5. Observação sobre o documento original

O PDF oficial reutiliza o cabeçalho *"ENTREGÁVEIS DA FASE 4"* na seção de entregáveis e é paginado
como *"Hackathon Página N de 8"*. É inconsistência de template da FIAP: **o conteúdo é da Fase 5**.
Registrado aqui para que a divergência não gere dúvida durante a execução.
