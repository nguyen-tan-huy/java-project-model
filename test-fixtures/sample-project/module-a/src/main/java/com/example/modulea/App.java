package com.example.modulea;

import com.example.moduleb.Greeter;

public class App {
    public static void main(String[] args) {
        String name = args.length > 0 ? args[0] : "world";
        System.out.println(new Greeter().greet(name));
    }
}
