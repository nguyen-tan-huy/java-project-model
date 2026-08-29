package com.example.modulea;

import com.example.moduleb.Greeter;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;

class AppTest {

    @Test
    void greetsWithName() {
        assertEquals("Hello, Neovim!", new Greeter().greet("Neovim"));
    }

    @Test
    void intentionallyFailingTest() {
        assertEquals("Hello, Neovim!", new Greeter().greet("Vim"));
    }
}
