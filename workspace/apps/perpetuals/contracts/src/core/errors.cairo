use perpetuals::core::types::PositionId;
use perpetuals::core::types::asset::AssetId;

pub const CANT_DELEVERAGE_PENDING_ASSET: felt252 = 'CANT_DELEVERAGE_PENDING_ASSET';
pub const CANT_TRADE_WITH_FEE_POSITION: felt252 = 'CANT_TRADE_WITH_FEE_POSITION';
pub const DIFFERENT_BASE_ASSET_IDS: felt252 = 'DIFFERENT_BASE_ASSET_IDS';
pub const DIFFERENT_QUOTE_ASSET_IDS: felt252 = 'DIFFERENT_QUOTE_ASSET_IDS';
pub const FEE_ASSET_AMOUNT_MISMATCH: felt252 = 'FEE_ASSET_AMOUNT_MISMATCH';
pub const INVALID_ACTUAL_BASE_SIGN: felt252 = 'INVALID_ACTUAL_BASE_SIGN';
pub const INVALID_ACTUAL_QUOTE_SIGN: felt252 = 'INVALID_ACTUAL_QUOTE_SIGN';
pub const INVALID_DELEVERAGE_BASE_CHANGE: felt252 = 'INVALID_DELEVERAGE_BASE_CHANGE';
pub const INVALID_NON_SYNTHETIC_ASSET: felt252 = 'INVALID_NON_SYNTHETIC_ASSET';
pub const INVALID_OWNER_SIGNATURE: felt252 = 'INVALID_ACCOUNT_OWNER_SIGNATURE';
pub const INVALID_QUOTE_AMOUNT_SIGN: felt252 = 'INVALID_QUOTE_AMOUNT_SIGN';
pub const INVALID_SAME_POSITIONS: felt252 = 'INVALID_SAME_POSITIONS';
pub const INVALID_WRONG_AMOUNT_SIGN: felt252 = 'INVALID_WRONG_AMOUNT_SIGN';
pub const INVALID_ZERO_AMOUNT: felt252 = 'INVALID_ZERO_AMOUNT';
pub const POSITION_UNHEALTHY: felt252 = 'POSITION_UNHEALTHY';
pub const SAME_BASE_QUOTE_ASSET_IDS: felt252 = 'SAME_BASE_QUOTE_ASSET_IDS';
pub const TRANSFER_EXPIRED: felt252 = 'TRANSFER_EXPIRED';
pub const WITHDRAW_EXPIRED: felt252 = 'WITHDRAW_EXPIRED';

pub fn fulfillment_exceeded_err(position_id: PositionId) -> ByteArray {
    format!("FULFILLMENT_EXCEEDED position_id: {:?}", position_id)
}

pub fn illegal_base_to_quote_ratio_err(position_id: PositionId) -> ByteArray {
    format!("ILLEGAL_BASE_TO_QUOTE_RATIO position_id: {:?}", position_id)
}

pub fn illegal_fee_to_quote_ratio_err(position_id: PositionId) -> ByteArray {
    format!("ILLEGAL_FEE_TO_QUOTE_RATIO position_id: {:?}", position_id)
}

pub fn invalid_funding_rate_err(synthetic_id: AssetId) -> ByteArray {
    format!("INVALID_FUNDING_RATE synthetic_id: {:?}", synthetic_id)
}

pub fn order_expired_err(position_id: PositionId) -> ByteArray {
    format!("ORDER_EXPIRED position_id: {:?}", position_id)
}

pub fn position_not_deleveragable(position_id: PositionId) -> ByteArray {
    format!("POSITION_IS_NOT_DELEVERAGABLE position_id: {:?}", position_id)
}

pub fn position_not_fair_deleverage(position_id: PositionId) -> ByteArray {
    format!("POSITION_IS_NOT_FAIR_DELEVERAGE position_id: {:?}", position_id)
}

pub fn position_not_healthy_nor_healthier(position_id: PositionId) -> ByteArray {
    format!("POSITION_NOT_HEALTHY_NOR_HEALTHIER position_id: {:?}", position_id)
}

pub fn position_not_liquidatable(position_id: PositionId) -> ByteArray {
    format!("POSITION_IS_NOT_LIQUIDATABLE position_id: {:?}", position_id)
}
