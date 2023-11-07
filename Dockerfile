FROM openjdk:17
COPY target/springboot-argocd.jar springboot-argocd.jar
EXPOSE 8080
ENTRYPOINT ["java","-jar","/springboot-argocd.jar"]