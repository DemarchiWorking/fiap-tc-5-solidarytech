# Plano de Continuidade de Negócios — SolidaryTech

> **Documento executivo.** Destinado à diretoria da SolidaryTech, não ao time de
> engenharia. Requisito **F4.1**; evidência visual obrigatória do relatório (E3.5).
>
> Versão 1.0 · 2026-09-05 · Revisão semestral

---

## 1. Sumário executivo

A SolidaryTech ganhou destaque em rede nacional e passou a receber picos de
acesso imprevisíveis. A diretoria estabeleceu uma regra que orienta todo este
documento:

> **"Se a nuvem cair, as doações não podem parar."**

Este plano responde a três perguntas de negócio:

| Pergunta | Resposta |
|---|---|
| Quanto tempo ficamos fora do ar? | **Até 1 hora** para doações (RTO) |
| Quanto dado podemos perder? | **Até 15 minutos** de doações (RPO) |
| Quanto custa essa garantia? | **US$ 12/mês** em backup, mais US$ 134/mês **apenas quando** a região secundária é ativada |

**O compromisso é assimétrico de propósito.** Uma doação perdida é dinheiro que
uma ONG não recebe e um doador que provavelmente não tenta de novo. Um cadastro
de ONG perdido é um formulário reenviado. Tratar os dois com o mesmo rigor
custaria três vezes mais e não protegeria melhor o que importa.

---

## 2. Criticidade por serviço

| Serviço | Criticidade | RTO | RPO | Justificativa de negócio |
|---|---|---|---|---|
| **`donation-service`** | **Crítica** | **1 h** | **15 min** | É dinheiro em trânsito. Perder uma doação é perda financeira direta e dano de confiança |
| `ngo-service` | Alta | 4 h | 24 h | ONG já cadastrada continua recebendo doação. Só o cadastro novo para |
| `volunteer-service` | Média | 8 h | 24 h | Inscrição de voluntário tolera reenvio. Nenhum valor financeiro em trânsito |
| Observabilidade | Alta | 4 h | — | Sem ela a operação fica cega — mas nenhuma doação para |

---

## 3. Como o RPO de 15 minutos é sustentado

Não é uma promessa: é a soma de três mecanismos verificáveis.

| Camada | Mecanismo | RPO efetivo |
|---|---|---|
| **Doações (RDS)** | Point-In-Time Recovery, habilitado por `backup_retention_period = 7` | **~5 min** |
| **Voluntários (DynamoDB)** | Point-In-Time Recovery contínuo | **~5 min** |
| **Evento em trânsito (SQS)** | Retenção de 4 dias na fila + 14 dias na DLQ | **0** — a mensagem sobrevive à queda do consumidor |
| **Estado do cluster** | Velero, backup horário das aplicações | **1 h** |

**O detalhe de arquitetura que protege a doação.** O `donation-service` grava no
RDS **e** publica em SQS antes de confirmar ao doador. Se o `volunteer-service`
cair, o evento **fica na fila** — nada se perde. Se o banco cair, a doação não é
confirmada e o doador vê um erro honesto em vez de um sucesso falso.

Foi por isso que o desacoplamento por fila não foi tratado como detalhe técnico:
ele é o que torna o RPO de 15 minutos alcançável.

---

## 4. Estratégia de DR (F4.2)

O enunciado pede a **Opção A ou a B**. Entregamos **as duas** — elas protegem
contra falhas diferentes, e implementar só uma deixaria um flanco aberto.

### Opção A — Velero, backup cross-region

| Item | Valor |
|---|---|
| Ferramenta | Velero 8.1 + plugin AWS |
| Destino | Bucket S3 em **`us-west-2`** — região **diferente** da do cluster |
| Escopo | Manifestos de todos os namespaces da aplicação + snapshots de EBS |
| Frequência | **Horária** (aplicações, TTL 7 d) e **diária** (cluster completo, TTL 30 d) |
| Custo | ~US$ 1/mês |

**Backup na mesma região não protege contra falha regional** — que é justamente o
cenário que este plano existe para cobrir. Por isso o bucket fica em `us-west-2`.

**A decisão técnica que viabilizou isso no ambiente da faculdade:** o Velero
autentica pelo **IMDS do nó** (`credentials.useSecret: false`). A instalação
padrão exigiria IRSA — bloqueado no AWS Academy — ou uma access key estática, que
reintroduziria a vulnerabilidade que este projeto eliminou.

### Opção B — Warm standby por Terraform

| Item | Valor |
|---|---|
| Região | `us-west-2` |
| Comando | **`make dr-up`** |
| Tempo até o cluster pronto | ~20 min |
| Capacidade | 2 nós (contra 3), escalável após o failover |
| Custo | **US$ 0** enquanto desligado; ~US$ 134/mês se mantido ativo |

**O que prova a modularização:** o ambiente `dr-usw2` **não redefine nenhuma
infraestrutura**. Ele chama exatamente os mesmos módulos de `prod-use1`, com
outra região e capacidade reduzida.

Se o desenho não fosse de fato modular, seria preciso duplicar centenas de linhas
— e a duplicata divergiria da produção na primeira mudança. **É assim que planos
de DR morrem na prática:** não por não existirem, mas por descreverem um ambiente
que já não existe mais.

---

## 5. Cenários e procedimentos

| # | Cenário | Probabilidade | RTO estimado | Procedimento |
|---|---|---|---|---|
| 1 | Pod ou Deployment com falha | Alta | **90 s** | Automático — `self-heal.yml` |
| 2 | Perda de um nó | Média | **5 min** | Automático — o scheduler reagenda; PDB garante ≥1 réplica |
| 3 | Corrupção de dado no RDS | Baixa | **45 min** | PITR — restaurar para o instante anterior |
| 4 | Perda de namespace ou do cluster | Baixa | **50 min** | `velero restore` |
| 5 | **Falha regional completa** | Muito baixa | **~1 h** | `make dr-up` + `velero restore` + repontar o DNS |

Procedimentos passo a passo: [`runbook-dr.md`](runbook-dr.md).

---

## 6. Débitos declarados — o que o ambiente da faculdade impõe

Esta seção existe porque **omitir limitação é pior do que tê-la**. Cada item traz
o risco real e o desenho que seria adotado em produção.

| Limitação | Imposta por | Risco | Desenho em produção |
|---|---|---|---|
| **RDS sem Multi-AZ** | Learner Lab não suporta | Falha de AZ derruba o banco; recuperação depende de restore | Multi-AZ com failover automático (~60 s) |
| **Sem IRSA** | IAM/OIDC bloqueados | Todo pod do nó alcança as mesmas permissões da `LabRole` | Uma IAM role de menor privilégio por serviço |
| **Sem TLS no ingress** | ACM e Route 53 não liberados | Tráfego em HTTP | ACM + Route 53 + `redirect-to-https` |
| **Sem WAF** | Não liberado | Sem proteção contra OWASP Top 10 na borda | AWS WAF no ALB |
| **Nós em subnet pública** | Decisão de custo (ADR-003) | Superfície de ataque maior | NAT Gateway — `enable_nat_gateway = true` |
| **Sem CMK no etcd** | Gerenciar KMS é restrito | Secrets cifrados com chave da AWS, não própria | `encryption_config` com CMK dedicada |
| **Credencial estática no CI** | OIDC federado bloqueado | Segredo armazenado no GitHub | OIDC — zero segredo armazenado |
| **Um NAT Gateway (quando ligado)** | Custo | Perda de saída para a internet em uma AZ | Um NAT por AZ |

**Nenhum desses itens é descuido.** Todos são consequência do AWS Academy
Learner Lab, e todos têm o caminho de correção mapeado. Os que **são** decisão de
custo — nós em subnet pública, NAT único — estão marcados como tal e podem ser
revertidos com uma variável.

---

## 7. Testes do plano

Um plano de DR nunca testado é uma hipótese, não um plano.

| Teste | Frequência | Evidência |
|---|---|---|
| Restore do Velero em namespace apagado | Mensal | `docs/07-evidencias/` |
| `make dr-plan` na região secundária | A cada release | Log do `terraform plan` |
| Chaos drill (réplicas → 0) | Mensal | [`../03-sre/mttr-chaos-drill.md`](../03-sre/mttr-chaos-drill.md) |
| Restore por PITR do RDS | Trimestral | Registro de execução |

---

## 8. Comunicação durante um incidente

| Público | Quando | Canal | Conteúdo |
|---|---|---|---|
| **ONGs parceiras** | Indisponibilidade > 15 min | E-mail + status page | Impacto, previsão, **se houve perda de doação** |
| **Doadores** | Hot path afetado | Banner no site | Mensagem simples, sem jargão técnico |
| **Diretoria** | Todo P1 | Chamada + resumo escrito | Impacto financeiro, consumo de error budget, risco de violar o SLA |
| **Time** | Sempre | ChatOps | Detalhe técnico, `trace_id`, runbook |

**A pergunta que as ONGs sempre fazem primeiro é *"alguma doação se perdeu?"*.**
O plano de comunicação precisa respondê-la antes de ser perguntada — e o desenho
com SQS foi escolhido em boa medida para que a resposta possa ser **"não"**.

---

## 9. Papéis

| Papel | Responsabilidade | Acionado quando |
|---|---|---|
| **On-call** | Primeira resposta, executa runbook | Todo `page` |
| **Incident Commander** | Coordena, decide failover, comunica | Incidente > 30 min |
| **Tech Lead** | Decisão técnica de arquitetura | Escalonamento do on-call |
| **Diretoria** | Decisão de negócio (comunicado público, crédito de SLA) | Impacto > 1 h ou perda de dado |

**Somente o Incident Commander decide o failover regional.** É uma decisão cara e
difícil de reverter: com o standby ativo, voltar para a região primária exige
outra janela de indisponibilidade. Ela não pode ser tomada sozinho, às 3h da
manhã, por quem está no meio da mitigação.
