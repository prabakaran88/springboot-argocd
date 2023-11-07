FROM openjdk:17
COPY target/springboot-argocd-1.0-SNAPSHOT.jar springboot-argocd-1.0-SNAPSHOT.jar
EXPOSE 8080
ENTRYPOINT ["java","-jar","/springboot-argocd-1.0-SNAPSHOT.jar"]