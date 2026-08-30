package com.example.modulea;

public class LongRunningApp {
    public static void main(String[] args) throws InterruptedException {
        System.out.println("LongRunningApp started");
        Thread.sleep(120_000);
    }
}
