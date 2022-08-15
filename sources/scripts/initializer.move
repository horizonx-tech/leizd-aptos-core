module leizd::initializer {

    use leizd::repository;
    use leizd::system_status;

    public entry fun initialize(owner: &signer) {
        system_status::initialize(owner);
        repository::initialize(owner);
    }
}