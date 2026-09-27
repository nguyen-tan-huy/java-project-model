package com.example.modulea;

public class GreetableImpl implements Greetable {
    @Override
    public String greet(String name) {
        return "Hello, " + name + "!";
    }
}
