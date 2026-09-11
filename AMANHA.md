# Roteiro do dia da entrega

> Sequência exata, na ordem, do zero até o vídeo gravado. Tudo o que **não**
> depende de você já está pronto e validado — ver
> [`ESTADO-DA-ENTREGA.md`](ESTADO-DA-ENTREGA.md).

**Tempo total: ~2 h**, dos quais ~25 min são o Terraform e o ArgoCD trabalhando
sozinhos.

---

## 0 · Abrir o terminal certo — 1 min

```bash
wsl
```

```bash
tc5
```

> **Não use o CMD nem o PowerShell.** O Windows tem um `kubectl` que responde e
> não conhece este cluster — o sintoma é `dial tcp [::1]:8080`, que parece
> problema de rede e é problema de shell.

---

## 1 · Credenciais do lab — 2 min

No painel do AWS Academy: **Start Lab** → **AWS Details** → **AWS CLI: Show**.

Cole o bloco inteiro em `~/.aws/credentials` **dentro do WSL**:

```bash
nano ~/.aws/credentials
```

Confira:

```bash
./solidary pre-voo
```

**Espere `GO`.** Se vier `NO-GO` com *"credenciais INVÁLIDAS ou EXPIRADAS"*,
a colagem não pegou — as três linhas precisam estar lá, incluindo o
`aws_session_token`, que é a mais longa e a mais fácil de truncar.

---

## 2 · O ambiente ainda existe? — 1 min

O `lab-down` **não** foi executado na última sessão, então a infraestrutura
provavelmente continua na AWS. Descubra:

```bash
./solidary kubeconfig && ./solidary status
```

| Resultado | Vá para |
|---|---|
| 15 Applications `Synced` | **Passo 4** — está tudo no ar |
| Erro / cluster não existe | **Passo 3** — subir do zero |

---

## 3 · Subir do zero — ~25 min *(só se o passo 2 falhou)*

```bash
export DD_API_KEY="<a API key do Datadog>"
```

```bash
./solidary lab-up
```

```bash
./solidary configurar-repo && git add -A && git commit -m "chore: configura o GitOps para a sessao" && git push
```

```bash
./solidary deploy
```

> O `DD_API_KEY` só é necessário **nesta** etapa. Depois ele vive no Secret
> `apm-credentials`, que sobrevive enquanto o cluster existir.

---

## 4 · Tráfego — 6 min *(obrigatório antes de qualquer print)*

```bash
./solidary carga
```

```bash
kubectl -n solidary-loadtest get jobs -w
```

Espere `Complete`.

**Sem carga os painéis ficam vazios.** O p95 de latência aparece como `NaN` —
e está certo: `histogram_quantile` sobre janela vazia não tem o que calcular.
Um vídeo gravado com o ambiente ocioso prova que nada funciona.

---

## 5 · Conferir que está tudo de pé — 3 min

```bash
./solidary status
```

```bash
./solidary senhas
```

Guarde a URL base e as duas senhas — mudam a cada `lab-up`.

Teste rápido das três APIs (troque `<base>` pela URL que saiu acima):

```bash
curl -s <base>/ngo/ngos
```

```bash
curl -s -X POST <base>/donations -H 'Content-Type: application/json' -d '{"ngo_id":1,"amount":150.50,"donor_name":"Maria Silva"}'
```

Esperado: `200` e `201`.

---

## 6 · Ativar o Watchdog — 2 min

**https://us5.datadoghq.com** → **Watchdog** → habilitar para os três serviços.

É o que fecha o **AIOps da frente 3**. A carga do passo 4 já deu linha de base.

---

## 7 · Os 8 prints — ~30 min

Salve em `docs/07-evidencias/`.

| Arquivo | Onde |
|---|---|
| `f0-argocd.png` | `<base>/argocd/` — 15 Applications `Synced`/`Healthy` |
| `f0-pods-running.png` | `kubectl get pods -A \| grep solidary` |
| `f0-pipeline-verde.png` | Actions → execução verde |
| `f0-pipeline-bloqueio.png` | Actions → execução **reprovada pelo Trivy** |
| `f1-dashboard-sre.png` | Grafana → *SolidaryTech — SRE: SLOs e Error Budget* |
| `f2-dashboard-finops.png` | Grafana → *SolidaryTech — FinOps* |
| `f2-tags-console.png` | AWS → Tag Editor → `CostCenter = NGO-Core` |
| `f0-trace-distribuido.png` | Datadog → APM → Traces |

> A execução reprovada pelo Trivy **já existe** no histórico do Actions — o
> gate barrou 4 CVEs reais. Não precisa provocar.

---

## 8 · Gravar o vídeo — 20 min

Roteiro em [`docs/roteiro-video.md`](docs/roteiro-video.md).

---

## 9 · Fechar o relatório — 2 min

Me passe o link do vídeo. Eu preencho o último campo e gero o PDF.

Ou você mesmo:

```bash
python scripts/gerar-relatorio.py
```

*(pelo PowerShell — o WSL desta máquina está sem interop e não executa o Edge)*

---

## 10 · Encerrar — 2 min

```bash
./solidary lab-down
```

**US$ 6,73/dia.** O bucket de state não é afetado.

---

## Higiene, antes de entregar

- [ ] **Repositório privado** enquanto o histórico tiver `labsuser.ppk` e
      `ssourl.txt` (commit `8603b96`). Voltar a público depois de regenerar a
      chave no painel do lab.
- [ ] Apagar o **Environment** `AWS_ACCESS_KEY_ID` criado por engano
      (Settings → Environments).
- [ ] Pedir ao Leonardo a **rotação da `DD_API_KEY`** — ela está commitada em
      texto puro no repositório da Fase 4.

---

## Se algo der errado

| Sintoma | Causa provável |
|---|---|
| `dial tcp [::1]:8080` | `kubectl` do Windows — você está no CMD |
| `'aws' is not recognized` | CMD em vez do WSL |
| `ExpiredToken` | sessão do lab caiu — recole as credenciais |
| `HTTP 000` no curl | rolling update em andamento; espere 30 s |
| Painel com `No data` | falta carga — passo 4 |
| Pipeline não dispara | Actions → clique no **nome do workflow** na barra lateral, aí aparece o *Run workflow* |

Diagnóstico completo em
[`docs/10-validacao-passo-a-passo.md`](docs/10-validacao-passo-a-passo.md).
