class Overrides
  
  OVERRIDES = {
    'csi'                 => 'csi: crime scene investigation',
    'csi new york'        => 'csi ny',
    'human target 2010'   => 'human target',
    'law order svu'       => 'law order special victims unit',
    'shit my dad says'    => '$#*! my dad says',
    'the office'          => 'the office us'
  }
  
  def self.override(name)
    puts "Original >>> #{name}"

    name = name.gsub(' and ', ' ')
    name = name.gsub('.', ' ')
    override = OVERRIDES[name.downcase]
    name = override unless override.nil?

    puts "Overridden >> #{name}"
    name
  end
  
end