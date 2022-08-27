module leizd::price_oracle {

    use std::string;

    public fun price<C>(): u64 {
        // TODO: external interface
        1
    }

    public fun price_of(name: &string::String): u64 {
        name; // TODO: logic
        1
    }

    public fun volume(name: &string::String, amount: u64): u64 {
        amount * price_of(name)
    }
}