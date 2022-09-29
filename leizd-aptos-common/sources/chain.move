module leizd_aptos_common::chain {
  #[test_only]
  use aptos_framework::chain_id;
  #[test_only]
  use aptos_framework::genesis;
  #[test]
  fun test_chain() {
    genesis::setup();
    let id = chain_id::get();
    assert!(id == 4, 0);
  }
}