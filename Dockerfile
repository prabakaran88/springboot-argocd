FROM core.harbor.management.eks.us-west-2.aws.smarsh.cloud/smarsh/java-jre-17-alpine:1.0.1
COPY target/springboot-argocd.jar /opt/app/springboot-argocd.jar
EXPOSE 8080
ENTRYPOINT ["java","-jar","/opt/app/springboot-argocd.jar"]