package com.example.modulea;

/**
 * Superclass of Address with a getter-less field - like a Lombok @Getter base model
 * (BaseModelResource.name in a real project): #{helloBean.address.zip} must land on this field.
 */
public class Place {
    protected String zip = "10000";
}
