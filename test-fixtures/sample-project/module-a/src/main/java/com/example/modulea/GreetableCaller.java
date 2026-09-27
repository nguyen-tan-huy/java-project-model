package com.example.modulea;

public class GreetableCaller {
    public String call(Greetable g, String name) {
        return g.greet(name);
    }
}
