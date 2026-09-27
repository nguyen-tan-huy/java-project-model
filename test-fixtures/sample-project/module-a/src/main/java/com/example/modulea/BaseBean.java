package com.example.modulea;

/** Superclass of HelloBean - #{helloBean.version} resolves to an INHERITED getter. */
public abstract class BaseBean {
    public String getVersion() {
        return "1.0";
    }
}
