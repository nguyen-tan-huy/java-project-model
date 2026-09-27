package com.example.modulea;

/** Not a bean itself - only reachable as #{helloBean.address.city} (chained EL). */
public class Address extends Place {
    private String city = "Hanoi";
    private Country country = new Country();

    public String getCity() {
        return city;
    }

    public Country getCountry() {
        return country;
    }
}
