terraform {
  # 1.9 e o piso porque este projeto usa `precondition`/`postcondition` em
  # blocos lifecycle e `check` no nivel do modulo raiz — os mecanismos que
  # traduzem as restricoes do AWS Academy em falha rapida e com mensagem clara,
  # em vez de um AccessDenied cru quinze minutos depois do apply comecar.
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
