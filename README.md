# fiap-hackaton-infra

Executar o comando: aws configure

Informar a chave de acesso, chave de acesso secreta e região

Preencha os valores de access_key e secret_key no arquivo infra-hackathon-fiap.tf, nos locais onde essas informações forem requeridas

Executar os comandos terraform:

terraform init
terraform plan
terraform apply -auto-approve


Para desfazer os provisionamentos:

terraform destroy -auto-approve
