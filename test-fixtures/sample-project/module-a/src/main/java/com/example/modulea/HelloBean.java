package com.example.modulea;

import jakarta.inject.Named;
import java.util.List;

/** JSF backing bean fixture for jsf/nav.lua (test-fixtures/smoke_jsf_nav.lua). */
@Named
public class HelloBean extends BaseBean {
    private String name = "world";
    private boolean active;
    private Address address = new Address();

    public String getName() {
        return name;
    }

    public void setName(String name) {
        this.name = name;
    }

    public boolean isActive() {
        return active;
    }

    public String sayHello() {
        return "Hello, " + name + "!";
    }

    public Address getAddress() {
        return address;
    }

    public List<Item> getItems() {
        return List.of(new Item());
    }
}
