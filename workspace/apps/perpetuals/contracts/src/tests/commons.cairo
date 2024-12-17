use contracts_commons::test_utils::{TokenConfig, TokenState, TokenTrait};
use contracts_commons::test_utils::{set_account_as_app_role_admin, set_account_as_operator};
use perpetuals::core::interface::ICoreDispatcher;
use perpetuals::value_risk_calculator::interface::IValueRiskCalculatorDispatcher;
use snforge_std::{ContractClassTrait, DeclareResultTrait};
use starknet::ContractAddress;

pub(crate) mod constants {
    use contracts_commons::types::fixed_two_decimal::{FixedTwoDecimal, FixedTwoDecimalTrait};
    use contracts_commons::types::time::TimeDelta;
    use perpetuals::core::types::asset::{AssetId, AssetIdTrait};
    use starknet::{ContractAddress, contract_address_const};

    pub fn VALUE_RISK_CALCULATOR_CONTRACT_ADDRESS() -> ContractAddress {
        contract_address_const::<'VALUE_RISK_CALCULATOR_ADDRESS'>()
    }
    pub fn TOKEN_ADDRESS() -> ContractAddress {
        contract_address_const::<'TOKEN_ADDRESS'>()
    }
    pub fn RISK_FACTOR() -> FixedTwoDecimal {
        FixedTwoDecimalTrait::new(50)
    }
    pub fn GOVERNANCE_ADMIN() -> ContractAddress {
        contract_address_const::<'GOVERNANCE_ADMIN'>()
    }
    pub fn APP_ROLE_ADMIN() -> ContractAddress {
        contract_address_const::<'APP_ROLE_ADMIN'>()
    }
    pub fn OPERATOR() -> ContractAddress {
        contract_address_const::<'OPERATOR'>()
    }

    /// 1 day in seconds.
    pub const PRICE_VALIDATION_INTERVAL: TimeDelta = TimeDelta { seconds: 86400 };
    /// 1 day in seconds.
    pub const FUNDING_VALIDATION_INTERVAL: TimeDelta = TimeDelta { seconds: 86400 };
    pub const PRICE: u64 = 900;
    pub const MAX_FUNDING_RATE: u32 = 5;
    pub const COLLATERAL_NAME: felt252 = 'COLLATERAL_NAME';
    pub const COLLATERAL_SYMBOL: felt252 = 'COLLATERAL_SYMBOL';
    pub const COLLATERAL_DECIMALS: u8 = 6;
    pub const COLLATERAL_QUORUM: u8 = 0;
    pub const SYNTHETIC_NAME: felt252 = 'SYNTHETIC_NAME';
    pub const SYNTHETIC_SYMBOL: felt252 = 'SYNTHETIC_SYMBOL';
    pub const SYNTHETIC_DECIMALS: u8 = 6;
    pub const SYNTHETIC_QUORUM: u8 = 1;

    /// Assets IDs
    pub fn ASSET_ID() -> AssetId {
        AssetIdTrait::new(value: selector!("asset_id"))
    }
    pub fn ASSET_ID_1() -> AssetId {
        AssetIdTrait::new(value: selector!("asset_id_1"))
    }
    pub fn ASSET_ID_2() -> AssetId {
        AssetIdTrait::new(value: selector!("asset_id_2"))
    }
    pub fn ASSET_ID_3() -> AssetId {
        AssetIdTrait::new(value: selector!("asset_id_3"))
    }
    pub fn ASSET_ID_4() -> AssetId {
        AssetIdTrait::new(value: selector!("asset_id_4"))
    }
    pub fn ASSET_ID_5() -> AssetId {
        AssetIdTrait::new(value: selector!("asset_id_5"))
    }

    /// Risk factors
    pub fn RISK_FACTOR_1() -> FixedTwoDecimal {
        FixedTwoDecimalTrait::new(50)
    }
    pub fn RISK_FACTOR_2() -> FixedTwoDecimal {
        FixedTwoDecimalTrait::new(50)
    }
    pub fn RISK_FACTOR_3() -> FixedTwoDecimal {
        FixedTwoDecimalTrait::new(50)
    }
    pub fn RISK_FACTOR_4() -> FixedTwoDecimal {
        FixedTwoDecimalTrait::new(50)
    }
    pub fn RISK_FACTOR_5() -> FixedTwoDecimal {
        FixedTwoDecimalTrait::new(50)
    }
    /// Prices
    pub const PRICE_1: u64 = 900;
    pub const PRICE_2: u64 = 900;
    pub const PRICE_3: u64 = 900;
    pub const PRICE_4: u64 = 900;
    pub const PRICE_5: u64 = 900;
}

#[derive(Drop, Copy)]
pub struct CoreConfig {
    pub tv_tr_calculator: ContractAddress,
}

/// The `CoreState` struct represents the state of the Core contract.
/// It includes the contract address
#[derive(Drop, Copy)]
pub struct CoreState {
    pub address: ContractAddress,
}


#[derive(Drop, Copy)]
pub(crate) struct PerpetualsInitConfig {
    pub governance_admin: ContractAddress,
    pub app_role_admin: ContractAddress,
    pub operator: ContractAddress,
}

impl PerpetualsInitConfigDefault of Default<PerpetualsInitConfig> {
    fn default() -> PerpetualsInitConfig {
        PerpetualsInitConfig {
            governance_admin: constants::GOVERNANCE_ADMIN(),
            app_role_admin: constants::APP_ROLE_ADMIN(),
            operator: constants::OPERATOR(),
        }
    }
}

#[generate_trait]
pub impl CoreImpl of CoreTrait {
    fn deploy(self: CoreConfig) -> CoreState {
        let mut calldata = array![];
        self.tv_tr_calculator.serialize(ref calldata);
        let core_contract = snforge_std::declare("Core").unwrap().contract_class();
        let (core_contract_address, _) = core_contract.deploy(@calldata).unwrap();
        let core = CoreState { address: core_contract_address };
        core
    }

    fn dispatcher(self: CoreState) -> ICoreDispatcher {
        ICoreDispatcher { contract_address: self.address }
    }
}

#[derive(Drop, Copy)]
pub struct ValueRiskCalculatorConfig {}

/// The `CoreState` struct represents the state of the Core contract.
/// It includes the contract address
#[derive(Drop, Copy)]
pub struct ValueRiskCalculatorState {
    pub address: ContractAddress,
}


#[generate_trait]
pub impl ValueRiskCalculatorImpl of ValueRiskCalculatorTrait {
    fn deploy(self: ValueRiskCalculatorConfig) -> ValueRiskCalculatorState {
        let mut calldata = array![];
        let tv_tr_calculator_contract = snforge_std::declare("ValueRiskCalculator")
            .unwrap()
            .contract_class();
        let (tv_tr_calculator_contract_address, _) = tv_tr_calculator_contract
            .deploy(@calldata)
            .unwrap();
        let tv_tr_calculator = ValueRiskCalculatorState {
            address: tv_tr_calculator_contract_address,
        };
        tv_tr_calculator
    }

    fn dispatcher(self: ValueRiskCalculatorState) -> IValueRiskCalculatorDispatcher {
        IValueRiskCalculatorDispatcher { contract_address: self.address }
    }
}

pub(crate) fn set_default_roles(perpetuals_contract: ContractAddress, cfg: PerpetualsInitConfig) {
    set_account_as_app_role_admin(
        contract: perpetuals_contract,
        account: cfg.app_role_admin,
        governance_admin: cfg.governance_admin,
    );
    set_account_as_operator(
        contract: perpetuals_contract, account: cfg.operator, app_role_admin: cfg.app_role_admin,
    );
}

/// The `SystemConfig` struct represents the configuration settings for the entire system.
/// It includes configurations for the token, core,
#[derive(Drop, Copy)]
struct SystemConfig {
    pub token: TokenConfig,
    pub core: CoreConfig,
    pub tv_tr_calculator: ValueRiskCalculatorConfig,
}

/// The `SystemState` struct represents the state of the entire system.
/// It includes the state for the token, staking, minting curve, and reward supplier contracts,
/// as well as a base account identifier.
#[derive(Drop, Copy)]
pub struct SystemState {
    pub token: TokenState,
    pub core: CoreState,
    pub tv_tr_calculator: ValueRiskCalculatorState,
}


#[generate_trait]
pub impl SystemImpl of SystemTrait {
    /// Deploys the system configuration and returns the system state.
    fn deploy(self: SystemConfig) -> SystemState {
        let token = self.token.deploy();
        let tv_tr_calculator = self.tv_tr_calculator.deploy();
        let core = self.core.deploy();
        SystemState { token, core, tv_tr_calculator }
    }
}
