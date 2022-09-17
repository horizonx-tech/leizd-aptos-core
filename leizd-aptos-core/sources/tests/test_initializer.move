#[test_only]
module leizd::test_initializer {

    use leizd::risk_factor;
    use leizd::system_status;
    use leizd::trove_manager;
    use leizd::stability_pool;

    /// Called only once by the owner.
    public entry fun initialize(owner: &signer) {
        system_status::initialize(owner);
        risk_factor::initialize(owner);
        trove_manager::initialize(owner);
        stability_pool::initialize(owner);
    }
}