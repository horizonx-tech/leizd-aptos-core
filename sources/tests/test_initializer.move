#[test_only]
module leizd::test_initializer {

    use leizd::risk_factor;
    use leizd::system_status;
    use leizd::trove;
    use leizd::stability_pool;

    /// Called only once by the owner.
    public entry fun initialize(owner: &signer) {
        system_status::initialize(owner);
        risk_factor::initialize(owner);
        trove::initialize(owner);
        stability_pool::initialize(owner);
    }
}