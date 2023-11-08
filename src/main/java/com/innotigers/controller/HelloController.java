package com.innotigers.controller;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class HelloController {

    @Value("${greeting.message:mytestmsg}")
    private String msg;

    @GetMapping("/greeting/{name}")
    public String greeting(@PathVariable("name") String name) {
        return msg + " " + name;
    }
}
